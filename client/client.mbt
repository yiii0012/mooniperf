/// mooniperf client: speaks the iperf3 wire protocol, drives the measured
/// phase, prints iperf3-style interval/summary output or a `-J` JSON @report.
///
/// Task/queue layout (single-consumer discipline):
///   data tasks --CMsg--> reporter task --RMsg--> control task (this body)
/// The reporter is the only consumer of the data queue; the control task
/// only consumes the small report queue, so counters never split.
///
/// Ordering note: the client closes its data sockets right *before* sending
/// TEST_END. iperf3 closes them slightly later; closing first makes the
/// receiver's final accounting deterministic (its EOF-driven final push
/// lands before the result exchange) without breaking the protocol.

///|
/// Version string announced in parameters and reports.
pub const VERSION : String = "mooniperf 0.1.3-pre"

///|
pub(all) struct ClientConfig {
  host : String
  port : Int32
  /// Duration of the measured window in seconds (-t).
  time : Int32
  /// Warm-up seconds excluded from results (-O).
  omit : Int32
  /// Interval length in seconds (-i).
  interval : Double
  /// Parallel streams (-P).
  parallel : Int32
  /// Reverse mode (-R): the server sends, we receive.
  reverse : Bool
  /// UDP test (-u).
  udp : Bool
  /// UDP target bitrate in bits/s (-b); 0 = iperf3 default 1 Mbit/s.
  bandwidth : Int64
  /// Block size (-l); 0 = protocol default.
  blksize : Int32
  /// Total byte limit (-n); 0 = unlimited.
  num_bytes : Int64
  /// Total block limit (-k); 0 = unlimited.
  blockcount : Int64
  /// Window size (-w): accepted but not applied (no setsockopt yet).
  window : Int32
  /// --get-server-output: ask the server to send its summary text back.
  get_server_output : Bool
  /// JSON output (-J).
  json : Bool
}

///|
/// Per-stream client-side counters, keyed by stream id.
priv struct CStats {
  bytes : Map[Int32, Int64]
  packets : Map[Int32, Int64]
  jitter : Map[Int32, Double]
  done : Map[Int32, Bool]
}

///|
fn CStats::new() -> CStats {
  { bytes: Map([]), packets: Map([]), jitter: Map([]), done: Map([]), }
}

///|
/// Per-stream snapshot at the last interval boundary.
priv struct LastSnap {
  t_ms : Int64
  bytes : Int64
  packets : Int64
}

///|
fn LastSnap::new(t_ms : Int64, bytes : Int64, packets : Int64) -> LastSnap {
  { t_ms, bytes, packets, }
}

///|
/// A recorded reporting interval (for the `-J` report).
priv struct IRecord {
  socket : Int32
  start : Double
  end : Double
  bytes : Int64
  packets : Int64
  omitted : Bool
}

///|
/// data tasks -> reporter task.
priv enum CMsg {
  Prog(Int32, Int64, Int64)
  UdpProg(Int32, Int64, Int64, Double)
  Done(Int32)
}

///|
/// reporter task -> control task.
priv enum RMsg {
  Final(CStats)
  Intervals(Array[IRecord])
}

///|
/// Run a client test; returns the process exit code.
pub async fn run_client(cfg : ClientConfig) -> Int32 {
  if !cfg.json {
    println("Connecting to host \{cfg.host}, port \{cfg.port}")
  }
  let addr = match
    (Some(@socket.Addr::resolve(cfg.host, port=cfg.port)) catch { _ => None }) {
    Some(a) => a
    None => {
      err_line(cfg.json, "unable to resolve address \{cfg.host}")
      return 1
    }
  }
  let conn = @socket.Tcp::connect(addr)
  let cookie = @ctl.new_cookie()
  @wire.write_cookie(conn, cookie)
  let blksize = effective_blksize(cfg)
  // PARAM_EXCHANGE: answer with our parameters.
  if !expect_state(conn, @ctl.PARAM_EXCHANGE, cfg.json) {
    conn.close()
    return 1
  }
  let params = build_params(cfg, blksize)
  @wire.write_json_msg(conn, params.to_json())
  // CREATE_STREAMS: open the data connections.
  if !expect_state(conn, @ctl.CREATE_STREAMS, cfg.json) {
    conn.close()
    return 1
  }
  let streams : Array[@socket.Tcp] = []
  let mut udp_sock : @socket.UdpServer? = None
  if cfg.udp {
    match udp_handshake(addr) {
      Some(ds) => udp_sock = Some(ds)
      None => {
        err_line(cfg.json, "UDP handshake failed")
        conn.close()
        return 1
      }
    }
  } else {
    let mut i = 0
    while i < cfg.parallel {
      let c = @socket.Tcp::connect(addr)
      @wire.write_cookie(c, cookie)
      streams.push(c)
      if !cfg.json {
        let id = @ctl.stream_id(i + 1)
        println(
          "[  \{id}] local \{c.addr().to_string()} connected to \{cfg.host} port \{cfg.port}",
        )
      }
      i += 1
    }
  }
  // TEST_START then TEST_RUNNING from the server.
  if !expect_state(conn, @ctl.TEST_START, cfg.json) {
    cleanup_streams(streams, udp_sock)
    conn.close()
    return 1
  }
  if !expect_state(conn, @ctl.TEST_RUNNING, cfg.json) {
    cleanup_streams(streams, udp_sock)
    conn.close()
    return 1
  }
  if !cfg.json {
    println("[ ID] Interval           Transfer     Bitrate")
  }
  let t0 = @async.now()
  let deadline = t0 + (cfg.omit + cfg.time).to_int64() * 1000L
  let omit_end = t0 + cfg.omit.to_int64() * 1000L
  // Byte/block limits are totals across streams, split per stream like iperf3.
  let per_stream_bytes = split_limit(cfg.num_bytes, cfg.parallel)
  let per_stream_blocks = split_limit(cfg.blockcount, cfg.parallel)
  let st = CStats::new()
  let q : @aqueue.Queue[CMsg] = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
  let rq : @async.Queue[RMsg] = @aqueue.Queue(kind=@aqueue.Kind::Unbounded)
  // Effective send target: -b not given -> UDP 1 Mbit/s / TCP unlimited;
  // -b 0 -> unlimited; -b >0 paces both UDP and TCP.
  let br = send_bitrate(cfg.bandwidth, cfg.udp)
  let code = @async.with_task_group(g => {
    // --- data tasks ---
    if cfg.udp {
      match udp_sock {
        Some(ds) =>
          if cfg.reverse {
            spawn_udp_receiver(
              g,
              q,
              ds,
              1,
              blksize,
              params.udp_counters_64bit == 1,
              omit_end,
            )
          } else {
            spawn_udp_sender(
              g, q, ds, addr, 1, blksize, br, t0, deadline, per_stream_bytes, per_stream_blocks,
            )
          }
        None => ()
      }
    } else {
      let mut i = 0
      while i < streams.length() {
        let c = streams[i]
        let id = @ctl.stream_id(i + 1)
        if cfg.reverse {
          spawn_tcp_receiver(g, q, c, id, blksize)
        } else {
          spawn_tcp_sender(
            g, q, c, id, t0, deadline, blksize, per_stream_bytes, per_stream_blocks,
            br,
          )
        }
        i += 1
      }
    }
    // --- reporter: the single consumer of the data queue ---
    g.spawn_bg(
      () => reporter_loop(q, rq, cfg, t0, deadline, omit_end),
      no_wait=true,
    )
    // --- control task waits for the reporter's final report ---
    let mut intervals : Array[IRecord] = []
    let mut final_seen = false
    while !final_seen && @async.now() < deadline + 5000L {
      @async.sleep(50)
      while true {
        let r = rq.try_get() catch { _ => None }
        match r {
          Some(RMsg::Final(s)) => {
            copy_stats(s, st)
            final_seen = true
          }
          Some(RMsg::Intervals(recs)) => intervals = recs
          None => break
        }
      }
      if final_seen {
        break
      }
    }
    // --- close data sockets, then TEST_END ---
    cleanup_streams(streams, udp_sock)
    @wire.write_state(conn, @ctl.TEST_END)
    // --- EXCHANGE_RESULTS: client sends its results first ---
    let code2 = if !expect_state(conn, @ctl.EXCHANGE_RESULTS, cfg.json) {
      1
    } else {
      @wire.write_json_msg(conn, client_results(cfg, st, t0).to_json())
      let server_results = match @wire.read_json_msg(conn) {
        Some(j) => @ctl.Results::from_json(j)
        None => {
          err_line(cfg.json, "no server results received")
          @ctl.Results::single(empty_stream())
        }
      }
      if !expect_state(conn, @ctl.DISPLAY_RESULTS, cfg.json) {
        conn.close()
        1
      } else {
        let end_t = @async.now()
        if cfg.json {
          println(
            build_json_report(cfg, st, intervals, server_results, t0, end_t).stringify(),
          )
        } else {
          print_final(cfg, st, server_results, t0, end_t)
          // --get-server-output: surface the server's own summary after
          // ours, like iperf3 does (in -J mode it rides inside the report).
          if cfg.get_server_output && server_results.server_output_text != "" {
            println("")
            println("Server output:")
            println(server_results.server_output_text)
          }
        }
        @wire.write_state(conn, @ctl.IPERF_DONE)
        conn.close()
        0
      }
    }
    code2
  })
  code
}

///|
fn effective_blksize(cfg : ClientConfig) -> Int32 {
  if cfg.blksize > 0 {
    cfg.blksize
  } else if cfg.udp {
    @ctl.DEFAULT_UDP_BLKSIZE
  } else {
    @ctl.DEFAULT_TCP_BLKSIZE
  }
}

///|
/// Resolve the effective send target from `-b` (bits/s).
///
/// `-1` (option not given) falls back to iperf3's defaults: 1 Mbit/s for
/// UDP, unlimited for TCP. `0` means unlimited (iperf3 semantics, UDP
/// included), and any positive value paces both UDP and TCP with the
/// time-driven block schedule (`stats/target_datagrams`).
fn send_bitrate(bandwidth : Int64, udp : Bool) -> Int64 {
  if bandwidth >= 0L {
    bandwidth
  } else if udp {
    @ctl.DEFAULT_UDP_BANDWIDTH
  } else {
    0L
  }
}

///|
/// Split a total limit across streams (at least 1 per stream).
fn split_limit(total : Int64, streams : Int32) -> Int64 {
  if total <= 0L {
    return 0L
  }
  let s = if streams < 1 { 1 } else { streams }
  let per = total / s.to_int64()
  if per < 1L {
    1L
  } else {
    per
  }
}

///|
/// Build the PARAM_EXCHANGE parameters from the client config.
fn build_params(cfg : ClientConfig, blksize : Int32) -> @ctl.Params {
  let p = @ctl.Params::default_params()
  p.tcp = !cfg.udp
  p.udp = cfg.udp
  p.omit = cfg.omit
  p.time = cfg.time
  p.num = cfg.num_bytes
  p.blockcount = cfg.blockcount
  p.parallel = cfg.parallel
  p.reverse = cfg.reverse
  p.window = cfg.window
  p.len = blksize
  // iperf3 sends the bandwidth key only when the rate is set and non-zero
  // (send_parameters); -b 0 stays absent on the wire.
  p.bandwidth = if cfg.bandwidth > 0L { cfg.bandwidth } else { 0L }
  p.pacing_timer = @ctl.DEFAULT_PACING_TIMER
  p.get_server_output = if cfg.get_server_output { 1 } else { 0 }
  p.client_version = VERSION
  p
}

///|
/// UDP announce/reply handshake towards `addr`. Uses an unconnected
/// `UdpServer` socket with sendto/recvfrom because connected UDP datagrams
/// are not reliably delivered on the Windows event loop.
async fn udp_handshake(addr : @socket.Addr) -> @socket.UdpServer? {
  let usock = match
    (Some(@socket.UdpServer(@socket.Addr::parse("0.0.0.0:0"))) catch {
      _ => None
    }) {
    Some(d) => d
    None => return None
  }
  let ok2 = try {
    usock.sendto(@ctl.udp_connect_msg(), addr)
    true
  } catch {
    _ => false
  }
  if !ok2 {
    usock.close()
    return None
  }
  let buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let mut ready = false
  let mut tries = 0
  while !ready && tries < 50 {
    let (n, _) = usock.recvfrom(buf, max_len=65536)
    if n <= 0 {
      break
    }
    if n >= 4 && @ctl.is_udp_connect_reply(@wire.bytes_of(buf, 4)) {
      ready = true
    }
    tries += 1
  }
  if ready {
    Some(usock)
  } else {
    usock.close()
    None
  }
}

///|
/// Print a runtime error line: plain "iperf3: error - ..." text, or a
/// machine-readable {"error": ...} JSON object in -J mode (iperf3 routes
/// errors through iperf_err, which emits JSON when output is JSON).
fn err_line(json : Bool, msg : String) -> Unit {
  if json {
    println(@ctl.jobj([("error", @ctl.jstr(msg))]).stringify())
  } else {
    println("iperf3: error - \{msg}")
  }
}

///|
/// Read one state byte and handle the error states; `true` when the wanted
/// state arrived.
async fn expect_state(conn : @socket.Tcp, want : Int32, json : Bool) -> Bool {
  match @wire.read_state(conn) {
    Some(s) =>
      if s == want {
        true
      } else if s == @ctl.SERVER_ERROR {
        // -2 followed by two big-endian u32 words (i_errno, errno). The
        // i_errno is an iperf3 wire code; render its documented text like
        // iperf3's iperf_strerror would.
        match @wire.read_n(conn, 8) {
          Some(payload) => {
            let (i_errno, errno) = @ctl.decode_server_error_body(payload)
            match @ctl.i_errno_to_text(i_errno) {
              Some(text) => err_line(json, text)
              None => err_line(json, "server error \{i_errno} (errno \{errno})")
            }
            false
          }
          None => {
            err_line(json, "server closed the control connection")
            false
          }
        }
      } else if s == @ctl.ACCESS_DENIED {
        err_line(json, "the server is busy running a test. try again later")
        false
      } else if s == @ctl.SERVER_TERMINATE {
        err_line(json, "the server has terminated")
        false
      } else {
        err_line(json, "unexpected state \{s}")
        false
      }
    None => {
      err_line(json, "control connection closed")
      false
    }
  }
}

///|
/// Absorb a data message into the stats maps.
fn absorb(msg : CMsg, st : CStats) -> Unit {
  match msg {
    CMsg::Prog(id, b, pk) => {
      st.bytes[id] = b
      st.packets[id] = pk
      st.done[id] = false
    }
    CMsg::UdpProg(id, b, pk, j) => {
      st.bytes[id] = b
      st.packets[id] = pk
      st.jitter[id] = j
      st.done[id] = false
    }
    CMsg::Done(id) => st.done[id] = true
  }
  ()
}

///|
fn drain(q : @aqueue.Queue[CMsg], st : CStats) -> Unit {
  while true {
    let r = q.try_get() catch { _ => None }
    match r {
      Some(msg) => absorb(msg, st)
      None => break
    }
  }
  ()
}

///|
fn copy_stats(src : CStats, dst : CStats) -> Unit {
  for id in src.bytes.keys() {
    dst.bytes[id] = mget64(src.bytes, id, 0L)
  }
  for id in src.packets.keys() {
    dst.packets[id] = mget64(src.packets, id, 0L)
  }
  for id in src.jitter.keys() {
    dst.jitter[id] = mgetd(src.jitter, id, 0.0)
  }
  for id in src.done.keys() {
    dst.done[id] = mgetb(src.done, id, false)
  }
  ()
}

///|
fn total_bytes(st : CStats) -> Int64 {
  let mut t : Int64 = 0L
  for id in st.bytes.keys() {
    t += mget64(st.bytes, id, 0L)
  }
  t
}

///|
fn total_packets(st : CStats) -> Int64 {
  let mut t : Int64 = 0L
  for id in st.packets.keys() {
    t += mget64(st.packets, id, 0L)
  }
  t
}

///|
fn cleanup_streams(
  streams : Array[@socket.Tcp],
  udp_sock : @socket.UdpServer?,
) -> Unit {
  for c in streams {
    c.close()
  }
  match udp_sock {
    Some(ds) => ds.close()
    None => ()
  }
  ()
}

///|
/// TCP sender (forward mode): bulk writes until the deadline/limits, or
/// time-driven block pacing when `-b > 0` is set (iperf3 paces TCP too).
fn spawn_tcp_sender(
  g : @async.TaskGroup[Int32],
  q : @aqueue.Queue[CMsg],
  c : @socket.Tcp,
  id : Int32,
  t0 : Int64,
  deadline : Int64,
  blksize : Int32,
  byte_limit : Int64,
  block_limit : Int64,
  bitrate : Int64,
) -> Unit {
  g.spawn_bg(
    () => {
      let pattern = make_payload(blksize)
      let mut sent : Int64 = 0L
      let mut blocks : Int64 = 0L
      let mut last = @async.now()
      while @async.now() < deadline {
        if byte_limit > 0L && sent >= byte_limit {
          break
        }
        if block_limit > 0L && blocks >= block_limit {
          break
        }
        // Paced mode: send whatever the schedule allows right now, then
        // sleep 1 ms and re-check (same scheme as the UDP sender).
        if bitrate > 0L {
          let elapsed = @async.now() - t0 + 1L
          let target = @stats.target_datagrams(elapsed, bitrate, blksize)
          if blocks >= target {
            @async.sleep(1)
            let now = @async.now()
            if now - last > 50L {
              q.put(CMsg::Prog(id, sent, blocks))
              last = now
            }
            continue
          }
        }
        c.write(pattern)
        sent += blksize.to_int64()
        blocks += 1L
        let now = @async.now()
        if now - last > 50L {
          q.put(CMsg::Prog(id, sent, blocks))
          last = now
        }
      }
      q.put(CMsg::Prog(id, sent, blocks))
      q.put(CMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
/// TCP receiver (reverse mode): count until EOF.
fn spawn_tcp_receiver(
  g : @async.TaskGroup[Int32],
  q : @aqueue.Queue[CMsg],
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
          q.put(CMsg::Prog(id, total, 0L))
          last = now
        }
      }
      q.put(CMsg::Prog(id, total, 0L))
      q.put(CMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
/// UDP sender (forward mode): time-driven pacing towards the target bitrate.
/// `bitrate <= 0` means unlimited (`-b 0`): no pacing cap, burst straight
/// through. Uses an unconnected socket with sendto (connected UDP datagrams
/// are not reliably delivered on the Windows event loop).
fn spawn_udp_sender(
  g : @async.TaskGroup[Int32],
  q : @aqueue.Queue[CMsg],
  ds : @socket.UdpServer,
  dst : @socket.Addr,
  id : Int32,
  blksize : Int32,
  bitrate : Int64,
  t0 : Int64,
  deadline : Int64,
  byte_limit : Int64,
  block_limit : Int64,
) -> Unit {
  g.spawn_bg(
    () => {
      let buf : FixedArray[Byte] = FixedArray::make(blksize, b'x')
      let mut sent : Int64 = 0L
      let mut pcount : Int64 = 0L
      let mut last = @async.now()
      while @async.now() < deadline {
        if byte_limit > 0L && sent >= byte_limit {
          break
        }
        if block_limit > 0L && pcount >= block_limit {
          break
        }
        // Send whatever the pacing schedule allows right now; at low rates
        // this is one datagram per interval, at high rates a small burst.
        // Unlimited mode has no cap (the 1 MiB burst just repeats).
        let elapsed = @async.now() - t0 + 1L
        let target = if bitrate > 0L {
          @stats.target_datagrams(elapsed, bitrate, blksize)
        } else {
          pcount + 1048576L
        }
        while pcount < target && @async.now() < deadline {
          if byte_limit > 0L && sent >= byte_limit {
            break
          }
          if block_limit > 0L && pcount >= block_limit {
            break
          }
          pcount += 1L
          stamp_datagram(buf, @async.now(), pcount)
          let _ = try {
            ds.sendto(Bytes::from_array(buf), dst)
            true
          } catch {
            _ => false
          }
          sent += blksize.to_int64()
        }
        @async.sleep(1)
        let now = @async.now()
        if now - last > 50L {
          q.put(CMsg::Prog(id, sent, pcount))
          last = now
        }
      }
      q.put(CMsg::Prog(id, sent, pcount))
      q.put(CMsg::Done(id))
    },
    no_wait=true,
  )
  ()
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
/// UDP receiver (reverse mode): feed the RFC 1889 estimator.
fn spawn_udp_receiver(
  g : @async.TaskGroup[Int32],
  q : @aqueue.Queue[CMsg],
  ds : @socket.UdpServer,
  id : Int32,
  blksize : Int32,
  counters64 : Bool,
  omit_end : Int64,
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
        let (n, _) = ds.recvfrom(buf, max_len=blksize)
        if n <= 0 {
          break
        }
        let probe = @wire.bytes_of(buf, if n < hdr_len { n } else { hdr_len })
        match @ctl.decode_datagram_header(probe, counters64) {
          Some((sec, usec, pcount)) => {
            let sent_ms = sec.to_int64() * 1000L + (usec / 1000).to_int64()
            let transit = (@async.now() - sent_ms).to_double() / 1000.0
            rcv.set_omitting(@async.now() < omit_end)
            rcv.on_datagram(pcount, transit, n)
          }
          None => ()
        }
        let now = @async.now()
        if now - last > 50L {
          q.put(
            CMsg::UdpProg(
              id,
              rcv.bytes_received,
              rcv.datagrams_received,
              rcv.jitter_ms(),
            ),
          )
          last = now
        }
      }
      q.put(
        CMsg::UdpProg(
          id,
          rcv.bytes_received,
          rcv.datagrams_received,
          rcv.jitter_ms(),
        ),
      )
      q.put(CMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

///|
/// The reporter: single consumer of the data queue. Prints interval lines,
/// records them for `-J`, and finally hands aggregates to the control task.
async fn reporter_loop(
  q : @aqueue.Queue[CMsg],
  rq : @async.Queue[RMsg],
  cfg : ClientConfig,
  t0 : Int64,
  deadline : Int64,
  omit_end : Int64,
) -> Unit {
  let st = CStats::new()
  let snaps : Map[Int32, LastSnap] = Map([])
  let records : Array[IRecord] = []
  // The CLI rejects -i <= 0; clamp here as defense in depth so the
  // next-report pointer can never get stuck (interval 0 would loop forever).
  let interval_ms = (cfg.interval * 1000.0).to_int64()
  let interval_ms = if interval_ms < 1L { 1L } else { interval_ms }
  let mut next = t0 + interval_ms
  while @async.now() < deadline {
    @async.sleep(25)
    drain(q, st)
    // Limits reached -> stop early like the senders do.
    let limit_hit = (cfg.num_bytes > 0L && total_bytes(st) >= cfg.num_bytes) ||
      (cfg.blockcount > 0L && total_packets(st) >= cfg.blockcount)
    let now = @async.now()
    while now >= next && next < deadline {
      let start = next - interval_ms
      let end = next
      let omitted = end <= omit_end
      for id in st.bytes.keys() {
        let cur_bytes = mget64(st.bytes, id, 0L)
        let cur_pkts = mget64(st.packets, id, 0L)
        let prev = match snaps.get(id) {
          Some(p) => p
          None => LastSnap::new(t0, 0L, 0L)
        }
        let d = @stats.Delta::between(
          @stats.Snapshot::new(prev.t_ms, prev.bytes, prev.packets),
          @stats.Snapshot::new(end, cur_bytes, cur_pkts),
        )
        if !omitted && !cfg.json {
          let sb = StringBuilder()
          sb.write_string(
            @report.interval_prefix(
              id,
              (start - t0).to_double() / 1000.0,
              (end - t0).to_double() / 1000.0,
            ),
          )
          sb.write_string(@report.pad_right(@report.fmt_bytes(d.bytes), 13))
          sb.write_string(@report.fmt_bps(d.bits_per_second))
          println(sb.to_string())
        }
        records.push({
          socket: id,
          start: (start - t0).to_double() / 1000.0,
          end: (end - t0).to_double() / 1000.0,
          bytes: d.bytes,
          packets: d.packets,
          omitted,
        })
        snaps[id] = LastSnap::new(end, cur_bytes, cur_pkts)
      }
      next += interval_ms
    }
    if limit_hit {
      break
    }
  }
  drain(q, st)
  rq.put(RMsg::Intervals(records))
  rq.put(RMsg::Final(st))
  ()
}

///|
/// Sender-side (or reverse receiver-side) results for EXCHANGE_RESULTS.
fn client_results(cfg : ClientConfig, st : CStats, t0 : Int64) -> @ctl.Results {
  let streams : Array[@ctl.StreamResult] = []
  for id in st.bytes.keys() {
    let bytes = mget64(st.bytes, id, 0L)
    let packets = mget64(st.packets, id, 0L)
    if cfg.udp && cfg.reverse {
      streams.push({
        id,
        bytes,
        retransmits: -1L,
        jitter: mgetd(st.jitter, id, 0.0),
        errors: -1L,
        omitted_errors: 0L,
        packets,
        omitted_packets: 0L,
        start_time: cfg.omit.to_double(),
        end_time: (@async.now() - t0).to_double() / 1000.0,
      })
    } else if cfg.udp {
      streams.push({
        id,
        bytes,
        retransmits: -1L,
        jitter: 0.0,
        errors: -1L,
        omitted_errors: 0L,
        packets,
        omitted_packets: 0L,
        start_time: cfg.omit.to_double(),
        end_time: (@async.now() - t0).to_double() / 1000.0,
      })
    } else {
      streams.push({
        id,
        bytes,
        retransmits: -1L,
        jitter: 0.0,
        errors: -1L,
        omitted_errors: 0L,
        packets: -1L,
        omitted_packets: 0L,
        start_time: cfg.omit.to_double(),
        end_time: (@async.now() - t0).to_double() / 1000.0,
      })
    }
  }
  if streams.is_empty() {
    streams.push(empty_stream())
  }
  {
    cpu_util_total: 0.0,
    cpu_util_user: 0.0,
    cpu_util_system: 0.0,
    sender_has_retransmits: 0L,
    streams,
    // The client never rides its own summary in the results JSON; only
    // the server does that (when --get-server-output was requested).
    server_output_text: "",
  }
}

///|
fn empty_stream() -> @ctl.StreamResult {
  {
    id: 1,
    bytes: 0L,
    retransmits: -1L,
    jitter: 0.0,
    errors: -1L,
    omitted_errors: 0L,
    packets: -1L,
    omitted_packets: 0L,
    start_time: 0.0,
    end_time: 0.0,
  }
}

///|
/// The iperf3 payload: a block filled with 'x' (0x78).
fn make_payload(blksize : Int32) -> Bytes {
  Bytes::from_array(FixedArray::make(blksize, b'x'))
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

///|
fn mgetb(m : Map[Int32, Bool], k : Int32, d : Bool) -> Bool {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}
