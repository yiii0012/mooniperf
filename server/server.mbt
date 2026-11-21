/// mooniperf server: speaks the iperf3 wire protocol on a TCP control
/// connection (plus UDP for `-u` tests) and measures the receiving side.
///
/// Protocol flow (forward mode, matching iperf3's iperf_server_api.c):
///   1. accept ctl connection, read the 37-byte cookie
///   2. send PARAM_EXCHANGE, read the parameters JSON
///   3. accept data connections (cookie check, ACCESS_DENIED on mismatch),
///      or complete the UDP connect handshake for `-u`
///   4. send TEST_START, then TEST_RUNNING
///   5. count bytes until the client sends TEST_END and closes its data
///      sockets (the client closes before TEST_END so the receiver's final
///      push lands deterministically)
///   6. EXCHANGE_RESULTS: read client results JSON, then send our own
///   7. DISPLAY_RESULTS, wait for IPERF_DONE

///|
/// Per-stream receiver accounting collected from the data tasks.
priv struct TestStats {
  bytes : Map[Int32, Int64]
  packets : Map[Int32, Int64]
  jitter : Map[Int32, Double]
  errors : Map[Int32, Int64]
  omitted : Map[Int32, Int64]
  done : Map[Int32, Bool]
}

///|
fn TestStats::new() -> TestStats {
  {
    bytes: Map([]),
    packets: Map([]),
    jitter: Map([]),
    errors: Map([]),
    omitted: Map([]),
    done: Map([]),
  }
}

///|
fn TestStats::all_done(self : TestStats, nstreams : Int32) -> Bool {
  self.done.length() >= nstreams
}

///|
/// Messages flowing from data-socket tasks into the control task.
priv enum SMsg {
  /// A TCP data connection completed its cookie handshake.
  Ready(@socket.Tcp)
  /// The UDP handshake completed; carries the client's data address.
  UdpReady(@socket.Addr)
  /// Periodic/final progress: (stream id, bytes).
  Prog(Int32, Int64)
  /// UDP progress: (id, bytes, packets_received, jitter_ms, errors, omitted).
  UdpProg(Int32, Int64, Int64, Double, Int64, Int64)
  /// The stream task finished (EOF or deadline).
  Done(Int32)
}

///|
/// Run the accept loop forever. Only returns (nonzero) if the listening
/// sockets cannot be created.
pub async fn run_server(port : Int32) -> Int32 {
  let addr = match
    (Some(@socket.Addr::parse("0.0.0.0:\{port}")) catch { _ => None }) {
    Some(a) => a
    None => {
      println("mooniperf: invalid port \{port}")
      return 2
    }
  }
  let listener = @socket.TcpServer(addr, reuse_addr=true)
  let udp = @socket.UdpServer(addr)
  println("-----------------------------------------------------------")
  println("Server listening on \{port} (iperf3-compatible)")
  println("-----------------------------------------------------------")
  while true {
    let (conn, peer) = listener.accept()
    handle_test(conn, peer, listener, udp)
  }
  0
}

///|
/// Drive one full test on a freshly accepted control connection.
async fn handle_test(
  conn : @socket.Tcp,
  peer : @socket.Addr,
  listener : @socket.TcpServer,
  udp : @socket.UdpServer,
) -> Unit {
  println("Accepted connection from \{peer.to_string()}")
  let cookie = match @wire.read_cookie(conn) {
    Some(c) => c
    None => {
      conn.close()
      return
    }
  }
  @wire.write_state(conn, @ctl.PARAM_EXCHANGE)
  let params_json = match @wire.read_json_msg(conn) {
    Some(j) => j
    None => {
      conn.close()
      return
    }
  }
  let params = @ctl.Params::from_json(params_json)
  let blksize = params.blocksize()
  // v0.1 measures UDP with a single stream (one handshake, one receiver);
  // a parallel UDP test would hang waiting for extra handshakes that never
  // come, so clamp here — this also keeps real iperf3 `-u -P N` clients
  // from deadlocking the server (documented limitation, see docs/roadmap.md).
  let nstreams = if params.udp { 1 } else { params.parallel }
  let q : @aqueue.Queue[SMsg] = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
  let _ = @async.with_task_group(g => {
    // --- stream acquisition ---
    if params.udp {
      g.spawn_bg(
        () => {
          let buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
          let (n, peer2) = udp.recvfrom(buf, max_len=65536)
          if n >= 4 {
            let probe = @wire.bytes_of(buf, 4)
            if @ctl.is_udp_connect_msg(probe) {
              // Reply from the listener port; the client accepts the
              // handshake reply from any source (like iperf3).
              let _ = try {
                udp.sendto(@ctl.udp_connect_reply(), peer2)
                true
              } catch {
                _ => false
              }
              q.put(SMsg::UdpReady(peer2))
            }
          }
        },
        no_wait=true,
      )
    } else {
      // Accept the data connections sequentially in ONE task. Concurrent
      // accept() calls on the same listener are not supported by the
      // async event loop (the second pending accept never wakes / can
      // panic the poller), and iperf3 itself accepts streams one by one.
      g.spawn_bg(
        () => {
          let mut i = 0
          while i < nstreams {
            let (c, _) = listener.accept()
            match @wire.read_cookie(c) {
              Some(ck) =>
                if @wire.same_bytes(ck, cookie) {
                  q.put(SMsg::Ready(c))
                } else {
                  // iperf3 answers a bad cookie with ACCESS_DENIED.
                  @wire.write_state(c, @ctl.ACCESS_DENIED)
                  c.close()
                }
              None => c.close()
            }
            i += 1
          }
        },
        no_wait=true,
      )
    }
    // CREATE_STREAMS: the client opens its data connections only after
    // receiving this state byte (iperf3 iperf_server_api.c order).
    @wire.write_state(conn, @ctl.CREATE_STREAMS)
    // Collect every stream (blocking gets).
    let streams : Array[@socket.Tcp] = []
    let mut udp_peer : @socket.Addr? = None
    let mut got = 0
    while got < nstreams {
      match q.get() {
        SMsg::Ready(c) => {
          streams.push(c)
          got += 1
        }
        SMsg::UdpReady(peer2) => {
          udp_peer = Some(peer2)
          got += 1
        }
        _ => ()
      }
    }
    // --- measured phase ---
    @wire.write_state(conn, @ctl.TEST_START)
    @wire.write_state(conn, @ctl.TEST_RUNNING)
    let t0 = @async.now()
    let deadline = t0 + params.total_seconds().to_int64() * 1000L
    if params.udp {
      match udp_peer {
        Some(peer2) =>
          if params.reverse {
            spawn_udp_sender(
              g,
              q,
              udp,
              peer2,
              1,
              params.bitrate(),
              deadline,
              blksize,
            )
          } else {
            spawn_udp_receiver(
              g,
              q,
              udp,
              1,
              blksize,
              params.udp_counters_64bit == 1,
            )
          }
        None => ()
      }
    } else if params.reverse {
      let mut i = 0
      while i < streams.length() {
        // Stream ids follow iperf3's quirky iperf_add_stream sequence
        // (1, 3, 4, ...), which both peers validate in EXCHANGE_RESULTS.
        spawn_tcp_sender(
          g,
          q,
          streams[i],
          @ctl.stream_id(i + 1),
          deadline,
          blksize,
        )
        i += 1
      }
    } else {
      let mut i = 0
      while i < streams.length() {
        spawn_tcp_receiver(g, q, streams[i], @ctl.stream_id(i + 1), blksize)
        i += 1
      }
    }
    // --- control loop ---
    let mut ok = true
    while true {
      match @wire.read_state(conn) {
        Some(s) =>
          if s == @ctl.TEST_END {
            break
          } else if s == @ctl.CLIENT_TERMINATE || s == @ctl.IPERF_DONE {
            ok = false
            break
          } else {
            ()
          }
        None => {
          ok = false
          break
        }
      }
    }
    // --- settle: wait for the data tasks' final pushes ---
    let st = TestStats::new()
    let mut rounds = 0
    while rounds < 10 && !st.all_done(nstreams) {
      drain(q, st)
      if !st.all_done(nstreams) {
        @async.sleep(50)
      }
      rounds += 1
    }
    drain(q, st)
    let end_s = (@async.now() - t0).to_double() / 1000.0
    // --- result exchange: server reads client results first, then sends
    // its own (client does send_results -> get_results) ---
    @wire.write_state(conn, @ctl.EXCHANGE_RESULTS)
    // The peer validates our result ids against ITS stream ids, so take
    // the id labels straight from the client's results JSON (in its stream
    // order) instead of assuming our own numbering; fall back to iperf3's
    // iperf_add_stream sequence when the peer sent no ids.
    let peer_ids : Array[Int32] = match @wire.read_json_msg(conn) {
      Some(j) => @ctl.Results::from_json(j).streams.map(fn(s) { s.id })
      None => []
    }
    @wire.write_json_msg(
      conn,
      build_results(params, st, end_s, peer_ids).to_json(),
    )
    @wire.write_state(conn, @ctl.DISPLAY_RESULTS)
    print_summary(params, st, end_s)
    // Client closes the data sockets around now; IPERF_DONE follows.
    let _ = @wire.read_state(conn)
    conn.close()
    g.return_immediately(())
    let _ = ok
  })
  ()
}

///|
/// Drain everything currently queued into the stats maps.
fn drain(q : @aqueue.Queue[SMsg], st : TestStats) -> Unit {
  while true {
    let r = q.try_get() catch { _ => None }
    match r {
      Some(SMsg::Prog(id, b)) => {
        st.bytes[id] = b
        st.done[id] = false
      }
      Some(SMsg::UdpProg(id, b, pk, j, e, o)) => {
        st.bytes[id] = b
        st.packets[id] = pk
        st.jitter[id] = j
        st.errors[id] = e
        st.omitted[id] = o
        st.done[id] = false
      }
      Some(SMsg::Done(id)) => st.done[id] = true
      Some(_) => ()
      None => break
    }
  }
  ()
}

///|
fn spawn_tcp_receiver(
  g : @async.TaskGroup[Unit],
  q : @aqueue.Queue[SMsg],
  c : @socket.Tcp,
  id : Int32,
  blksize : Int32,
) -> Unit {
  g.spawn_bg(
    () => {
      let buf : FixedArray[Byte] = FixedArray::make(blksize, b'\x00')
      let mut total : Int64 = 0L
      let mut last = @async.now()
      while true {
        let n = c.read(buf, max_len=blksize)
        if n <= 0 {
          break
        }
        total += n.to_int64()
        let now = @async.now()
        if now - last > 50L {
          q.put(SMsg::Prog(id, total))
          last = now
        }
      }
      q.put(SMsg::Prog(id, total))
      q.put(SMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
fn spawn_tcp_sender(
  g : @async.TaskGroup[Unit],
  q : @aqueue.Queue[SMsg],
  c : @socket.Tcp,
  id : Int32,
  deadline : Int64,
  blksize : Int32,
) -> Unit {
  g.spawn_bg(
    () => {
      let pattern = make_payload(blksize)
      let mut sent : Int64 = 0L
      let mut last = @async.now()
      while @async.now() < deadline {
        c.write(pattern)
        sent += blksize.to_int64()
        let now = @async.now()
        if now - last > 50L {
          q.put(SMsg::Prog(id, sent))
          last = now
        }
      }
      q.put(SMsg::Prog(id, sent))
      q.put(SMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
fn spawn_udp_receiver(
  g : @async.TaskGroup[Unit],
  q : @aqueue.Queue[SMsg],
  udp : @socket.UdpServer,
  id : Int32,
  blksize : Int32,
  counters64 : Bool,
) -> Unit {
  g.spawn_bg(
    () => {
      let rcv = @stats.UdpReceiver::new()
      let buf : FixedArray[Byte] = FixedArray::make(blksize, b'\x00')
      let hdr_len = if counters64 {
        @ctl.DATAGRAM_HEADER_SIZE_64
      } else {
        @ctl.DATAGRAM_HEADER_SIZE
      }
      let mut last = @async.now()
      while true {
        let (n, from) = udp.recvfrom(buf, max_len=blksize)
        if n <= 0 {
          break
        }
        if n >= 4 && @ctl.is_udp_connect_msg(@wire.bytes_of(buf, 4)) {
          // A (possibly extra) stream handshake, e.g. from a multi-stream
          // iperf3 `-u -P N` client: answer it so that stream does not hang
          // waiting for its reply, and do not count it as test data.
          let _ = try {
            udp.sendto(@ctl.udp_connect_reply(), from)
            true
          } catch {
            _ => false
          }
        } else {
          let probe = @wire.bytes_of(buf, if n < hdr_len { n } else { hdr_len })
          match @ctl.decode_datagram_header(probe, counters64) {
            Some((sec, usec, pcount)) => {
              // Sender timestamps are on the sender's clock; only the
              // difference against our arrival time is used, so clock offsets
              // cancel out (same differential jitter math as iperf3).
              let sent_ms = sec.to_int64() * 1000L + (usec / 1000).to_int64()
              let transit = (@async.now() - sent_ms).to_double() / 1000.0
              rcv.on_datagram(pcount, transit, n)
            }
            None => ()
          }
        }
        let now = @async.now()
        if now - last > 50L {
          q.put(
            SMsg::UdpProg(
              id,
              rcv.bytes_received,
              rcv.datagrams_received,
              rcv.jitter_ms(),
              rcv.cnt_error,
              rcv.omitted_cnt_error,
            ),
          )
          last = now
        }
      }
      q.put(
        SMsg::UdpProg(
          id,
          rcv.bytes_received,
          rcv.datagrams_received,
          rcv.jitter_ms(),
          rcv.cnt_error,
          rcv.omitted_cnt_error,
        ),
      )
      q.put(SMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
/// Reverse UDP: the server paces datagrams towards the client address
/// learned during the handshake, straight from the listener socket.
fn spawn_udp_sender(
  g : @async.TaskGroup[Unit],
  q : @aqueue.Queue[SMsg],
  udp : @socket.UdpServer,
  peer : @socket.Addr,
  id : Int32,
  bitrate : Int64,
  deadline : Int64,
  blksize : Int32,
) -> Unit {
  g.spawn_bg(
    () => {
      let buf : FixedArray[Byte] = FixedArray::make(blksize, b'x')
      let t0 = @async.now()
      let mut sent : Int64 = 0L
      let mut pcount : Int64 = 0L
      let mut last = @async.now()
      while @async.now() < deadline {
        // Time-driven pacing towards the negotiated bitrate.
        let elapsed = @async.now() - t0 + 1L
        let target = @stats.target_datagrams(elapsed, bitrate, blksize)
        while pcount < target && @async.now() < deadline {
          pcount += 1L
          stamp_datagram(buf, @async.now(), pcount)
          let ok = try {
            udp.sendto(Bytes::from_array(buf), peer)
            true
          } catch {
            _ => false
          }
          if !ok {
            break
          }
          sent += blksize.to_int64()
        }
        @async.sleep(1)
        let now = @async.now()
        if now - last > 50L {
          q.put(SMsg::Prog(id, sent))
          last = now
        }
      }
      q.put(SMsg::Prog(id, sent))
      q.put(SMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
/// Build the server-side (receiver) results for EXCHANGE_RESULTS. `peer_ids`
/// carries the stream ids as the CLIENT declared them (positional match with
/// our receiver ordinals, which sort ascending as 1, 3, 4, ...); entries past
/// its length fall back to iperf3's own id sequence.
fn build_results(
  params : @ctl.Params,
  st : TestStats,
  end_s : Double,
  peer_ids : Array[Int32],
) -> @ctl.Results {
  let ordinals = Array::from_iter(st.bytes.keys())
  ordinals.sort()
  let streams : Array[@ctl.StreamResult] = []
  let mut pos = 0
  for id in ordinals {
    let ordinal = pos + 1
    let out_id = if pos < peer_ids.length() {
      peer_ids[pos]
    } else {
      @ctl.stream_id(ordinal)
    }
    pos += 1
    let bytes = mget64(st.bytes, id, 0L)
    if params.udp {
      streams.push({
        id: out_id,
        bytes,
        retransmits: -1L,
        jitter: mgetd(st.jitter, id, 0.0),
        errors: mget64(st.errors, id, -1L),
        omitted_errors: mget64(st.omitted, id, 0L),
        packets: mget64(st.packets, id, -1L),
        omitted_packets: 0L,
        start_time: params.omit.to_double(),
        end_time: end_s,
      })
    } else {
      streams.push({
        id: out_id,
        bytes,
        retransmits: -1L,
        jitter: 0.0,
        errors: -1L,
        omitted_errors: 0L,
        packets: -1L,
        omitted_packets: 0L,
        start_time: params.omit.to_double(),
        end_time: end_s,
      })
    }
  }
  if streams.is_empty() {
    let fallback = if peer_ids.length() > 0 { peer_ids[0] } else { 1 }
    streams.push({
      id: fallback,
      bytes: 0L,
      retransmits: -1L,
      jitter: 0.0,
      errors: -1L,
      omitted_errors: 0L,
      packets: -1L,
      omitted_packets: 0L,
      start_time: params.omit.to_double(),
      end_time: end_s,
    })
  }
  {
    cpu_util_total: 0.0,
    cpu_util_user: 0.0,
    cpu_util_system: 0.0,
    sender_has_retransmits: 0L,
    streams,
  }
}

///|
/// iperf3-style final summary on the server console.
fn print_summary(params : @ctl.Params, st : TestStats, end_s : Double) -> Unit {
  println("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -")
  println("[ ID] Interval           Transfer     Bitrate")
  for id in st.bytes.keys() {
    let bytes = mget64(st.bytes, id, 0L)
    let bps = @stats.bits_per_second(bytes, end_s - params.omit.to_double())
    let sb = StringBuilder()
    sb.write_string(@report.interval_prefix(id, params.omit.to_double(), end_s))
    sb.write_string(@report.pad_right(@report.fmt_bytes(bytes), 13))
    sb.write_string(@report.fmt_bps(bps))
    if params.udp {
      sb.write_string("  \{@report.fixed(mgetd(st.jitter, id, 0.0), 3)} ms")
      let pk = mget64(st.packets, id, 0L)
      let e = mget64(st.errors, id, 0L)
      sb.write_string("  \{e}/\{pk}")
    }
    sb.write_string("    receiver")
    println(sb.to_string())
  }
  println("")
}

///|
/// Patch the 12-byte datagram header into a send buffer (32-bit counters).
fn stamp_datagram(
  buf : FixedArray[Byte],
  now_ms : Int64,
  pcount : Int64,
) -> Unit {
  let sec = (now_ms / 1000L).to_int()
  let usec = (now_ms % 1000L * 1000L).to_int()
  @ctl.put_u32_be(buf, 0, sec)
  @ctl.put_u32_be(buf, 4, usec)
  @ctl.put_u32_be(buf, 8, pcount.to_int())
  ()
}

///|
/// The iperf3 payload: a block filled with 'x' (0x78), built once per test.
fn make_payload(blksize : Int32) -> Bytes {
  let buf : FixedArray[Byte] = FixedArray::make(blksize, b'x')
  Bytes::from_array(buf)
}

///|
fn mget64(m : Map[Int32, Int64], k : Int32, d : Int64) -> Int64 {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}

///|
fn mgetd(m : Map[Int32, Double], k : Int32, d : Double) -> Double {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}
