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

/// Version string announced in parameters and reports.
pub const VERSION : String = "mooniperf 0.1.0"

pub(all) struct ClientConfig {
  host : String
  port : Int
  /// Duration of the measured window in seconds (-t).
  time : Int
  /// Warm-up seconds excluded from results (-O).
  omit : Int
  /// Interval length in seconds (-i).
  interval : Double
  /// Parallel streams (-P).
  parallel : Int
  /// Reverse mode (-R): the server sends, we receive.
  reverse : Bool
  /// UDP test (-u).
  udp : Bool
  /// UDP target bitrate in bits/s (-b); 0 = iperf3 default 1 Mbit/s.
  bandwidth : Int64
  /// Block size (-l); 0 = protocol default.
  blksize : Int
  /// Total byte limit (-n); 0 = unlimited.
  num_bytes : Int64
  /// Total block limit (-k); 0 = unlimited.
  blockcount : Int64
  /// Window size (-w): accepted but not applied (no setsockopt yet).
  window : Int
  /// JSON output (-J).
  json : Bool
}

/// Per-stream client-side counters, keyed by stream id.
priv struct CStats {
  bytes : Map[Int, Int64]
  packets : Map[Int, Int64]
  jitter : Map[Int, Double]
  done : Map[Int, Bool]
}

fn CStats::new() -> CStats {
  {
    bytes: Map::new(),
    packets: Map::new(),
    jitter: Map::new(),
    done: Map::new(),
  }
}

/// Per-stream snapshot at the last interval boundary.
priv struct LastSnap {
  t_ms : Int64
  bytes : Int64
  packets : Int64
}

fn LastSnap::new(t_ms : Int64, bytes : Int64, packets : Int64) -> LastSnap {
  { t_ms, bytes, packets }
}

/// A recorded reporting interval (for the `-J` report).
priv struct IRecord {
  socket : Int
  start : Double
  end : Double
  bytes : Int64
  packets : Int64
  omitted : Bool
}

/// data tasks -> reporter task.
priv enum CMsg {
  Prog(Int, Int64, Int64)
  UdpProg(Int, Int64, Int64, Double)
  Done(Int)
}

/// reporter task -> control task.
priv enum RMsg {
  Final(CStats)
  Intervals(Array[IRecord])
}

/// Run a client test; returns the process exit code.
pub async fn run_client(cfg : ClientConfig) -> Int {
  if !(cfg.json) {
    println("Connecting to host \{cfg.host}, port \{cfg.port}")
  }
  let addr = match (try Some(@socket.Addr::resolve(cfg.host, port=cfg.port)) catch {
    _ => None
  }) {
    Some(a) => a
    None => {
      println("iperf3: error - unable to resolve address \{cfg.host}")
      return 1
    }
  }
  let conn = @socket.Tcp::connect(addr)
  let cookie = @ctl.new_cookie()
  @wire.write_cookie(conn, cookie)
  let blksize = effective_blksize(cfg)
  // PARAM_EXCHANGE: answer with our parameters.
  if !(expect_state(conn, @ctl.PARAM_EXCHANGE, cfg.json)) {
    conn.close()
    return 1
  }
  let params = build_params(cfg, blksize)
  @wire.write_json_msg(conn, params.to_json())
  // CREATE_STREAMS: open the data connections.
  if !(expect_state(conn, @ctl.CREATE_STREAMS, cfg.json)) {
    conn.close()
    return 1
  }
  let streams : Array[@socket.Tcp] = []
  let mut udp_sock : @socket.UdpServer? = None
  if cfg.udp {
    match udp_handshake(addr) {
      Some(ds) => udp_sock = Some(ds)
      None => {
        println("iperf3: error - UDP handshake failed")
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
      if !(cfg.json) {
        let id = 5 + i
  println(
          "[  \{id}] local \{c.addr().to_string()} connected to \{cfg.host} port \{cfg.port}",
        )
      }
      i += 1
    }
  }
  // TEST_START then TEST_RUNNING from the server.
  if !(expect_state(conn, @ctl.TEST_START, cfg.json)) {
    cleanup_streams(streams, udp_sock)
    conn.close()
    return 1
  }
  if !(expect_state(conn, @ctl.TEST_RUNNING, cfg.json)) {
    cleanup_streams(streams, udp_sock)
    conn.close()
    return 1
  }
  if !(cfg.json) {
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
  let code = @async.with_task_group(
    g => {
      // --- data tasks ---
      if cfg.udp {
        match udp_sock {
          Some(ds) =>
            if cfg.reverse {
              spawn_udp_receiver(
                g,
                q,
                ds,
                5,
                blksize,
                params.udp_counters_64bit == 1,
                omit_end,
              )
            } else {
              spawn_udp_sender(
                g,
                q,
                ds,
                addr,
                5,
                blksize,
                params.bitrate(),
                t0,
                deadline,
                per_stream_bytes,
                per_stream_blocks,
              )
            }
          None => ()
        }
      } else {
        let mut i = 0
        while i < streams.length() {
          let c = streams[i]
          if cfg.reverse {
            spawn_tcp_receiver(g, q, c, 5 + i, blksize)
          } else {
            spawn_tcp_sender(
              g,
              q,
              c,
              5 + i,
              deadline,
              blksize,
              per_stream_bytes,
              per_stream_blocks,
            )
          }
          i += 1
        }
      }
      // --- reporter: the single consumer of the data queue ---
      g.spawn_bg(
        () => {
          reporter_loop(q, rq, cfg, t0, deadline, omit_end)
        },
        no_wait=true,
      )
      // --- control task waits for the reporter's final report ---
      let mut intervals : Array[IRecord] = []
      let mut final_seen = false
      while !(final_seen) && @async.now() < deadline + 5000L {
        @async.sleep(50)
        while true {
          let r = try rq.try_get() catch {
            _ => None
          }
          match r {
            Some(RMsg::Final(s)) => {
              copy_stats(s, st)
              final_seen = true
            }
            Some(RMsg::Intervals(recs)) => { intervals = recs }
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
          let code2 = if !(expect_state(conn, @ctl.EXCHANGE_RESULTS, cfg.json)) {
        1
      } else {
        @wire.write_json_msg(conn, client_results(cfg, st, t0).to_json())
        let server_results = match @wire.read_json_msg(conn) {
          Some(j) => @ctl.Results::from_json(j)
          None => {
            println("iperf3: error - no server results received")
            @ctl.Results::single(empty_stream())
          }
        }
        if !(expect_state(conn, @ctl.DISPLAY_RESULTS, cfg.json)) {
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
          }
          @wire.write_state(conn, @ctl.IPERF_DONE)
          conn.close()
          0
        }
      }
      code2
    },
  )
  code
}

fn effective_blksize(cfg : ClientConfig) -> Int {
  if cfg.blksize > 0 {
    cfg.blksize
  } else if cfg.udp {
    @ctl.DEFAULT_UDP_BLKSIZE
  } else {
    @ctl.DEFAULT_TCP_BLKSIZE
  }
}

/// Split a total limit across streams (at least 1 per stream).
fn split_limit(total : Int64, streams : Int) -> Int64 {
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

/// Build the PARAM_EXCHANGE parameters from the client config.
fn build_params(cfg : ClientConfig, blksize : Int) -> @ctl.Params {
  let p = @ctl.Params::default_params()
  p.tcp = !(cfg.udp)
  p.udp = cfg.udp
  p.omit = cfg.omit
  p.time = cfg.time
  p.num = cfg.num_bytes
  p.blockcount = cfg.blockcount
  p.parallel = cfg.parallel
  p.reverse = cfg.reverse
  p.window = cfg.window
  p.len = blksize
  p.bandwidth = cfg.bandwidth
  p.pacing_timer = @ctl.DEFAULT_PACING_TIMER
  p.client_version = VERSION
  p
}

/// datagrams are not delivered) and do the announce/reply handshake.
/// `UdpClient(addr)` binds an ephemeral port and connects to the peer.
async fn udp_handshake(addr : @socket.Addr) -> @socket.UdpServer? {
  let usock = match (try Some(@socket.UdpServer(@socket.Addr::parse("0.0.0.0:0"))) catch {
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
  if !(ok2) {
    usock.close()
    return None
  }
  let buf : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let mut ready = false
  let mut tries = 0
  while !(ready) && tries < 50 {
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

/// Read one state byte and handle the error states; `true` when the wanted
/// state arrived.
async fn expect_state(conn : @socket.Tcp, want : Int, json : Bool) -> Bool {
  match @wire.read_state(conn) {
    Some(s) =>
      if s == want {
        true
      } else if s == @ctl.SERVER_ERROR {
        // -2 followed by two big-endian u32 words (i_errno, errno).
        match @wire.read_n(conn, 8) {
          Some(payload) => {
            let (i_errno, errno) = @ctl.decode_server_error(payload)
            println("iperf3: error - server error \{i_errno} (errno \{errno})")
            false
          }
          None => {
            println("iperf3: error - server closed the control connection")
            false
          }
        }
      } else if s == @ctl.ACCESS_DENIED {
        println("iperf3: error - the server is busy")
        false
      } else if s == @ctl.SERVER_TERMINATE {
        if !(json) {
          println("iperf3: the server terminated early")
        }
        false
      } else {
        println("iperf3: error - unexpected state \{s}")
        false
      }
    None => {
      println("iperf3: error - control connection closed")
      false
    }
  }
}

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
    CMsg::Done(id) => { st.done[id] = true }
  }
  ()
}

fn drain(q : @aqueue.Queue[CMsg], st : CStats) -> Unit {
  while true {
    let r = try q.try_get() catch {
      _ => None
    }
    match r {
      Some(msg) => absorb(msg, st)
      None => break
    }
  }
  ()
}

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

fn total_bytes(st : CStats) -> Int64 {
  let mut t : Int64 = 0L
  for id in st.bytes.keys() {
    t += mget64(st.bytes, id, 0L)
  }
  t
}

fn total_packets(st : CStats) -> Int64 {
  let mut t : Int64 = 0L
  for id in st.packets.keys() {
    t += mget64(st.packets, id, 0L)
  }
  t
}

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

/// TCP sender (forward mode): unpaced bulk writes until the deadline/limits.
fn spawn_tcp_sender(
  g : @async.TaskGroup[Int],
  q : @aqueue.Queue[CMsg],
  c : @socket.Tcp,
  id : Int,
  deadline : Int64,
  blksize : Int,
  byte_limit : Int64,
  block_limit : Int64,
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

/// TCP receiver (reverse mode): count until EOF.
fn spawn_tcp_receiver(
  g : @async.TaskGroup[Int],
  q : @aqueue.Queue[CMsg],
  c : @socket.Tcp,
  id : Int,
  blksize : Int,
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

/// UDP sender (forward mode): time-driven pacing towards the target bitrate.
/// Uses an unconnected socket with sendto (connected UDP datagrams are not
/// reliably delivered on the Windows event loop).
fn spawn_udp_sender(
  g : @async.TaskGroup[Int],
  q : @aqueue.Queue[CMsg],
  ds : @socket.UdpServer,
  dst : @socket.Addr,
  id : Int,
  blksize : Int,
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
        let elapsed = @async.now() - t0 + 1L
        let target = @stats.target_datagrams(elapsed, bitrate, blksize)
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

/// Patch the 12-byte datagram header into a send buffer (32-bit counters).
fn stamp_datagram(buf : FixedArray[Byte], now_ms : Int64, pcount : Int64) -> Unit {
  let sec = (now_ms / 1000L).to_int()
  let usec = ((now_ms % 1000L) * 1000L).to_int()
  @ctl.put_u32_be(buf, 0, sec)
  @ctl.put_u32_be(buf, 4, usec)
  @ctl.put_u32_be(buf, 8, pcount.to_int())
  ()
}

/// UDP receiver (reverse mode): feed the RFC 1889 estimator.
fn spawn_udp_receiver(
  g : @async.TaskGroup[Int],
  q : @aqueue.Queue[CMsg],
  ds : @socket.UdpServer,
  id : Int,
  blksize : Int,
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
          q.put(CMsg::UdpProg(id, rcv.bytes_received, rcv.datagrams_received, rcv.jitter_ms()))
          last = now
        }
      }
      q.put(CMsg::UdpProg(id, rcv.bytes_received, rcv.datagrams_received, rcv.jitter_ms()))
      q.put(CMsg::Done(id))
    },
    no_wait=true,
  )
  ()
}

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
  let snaps : Map[Int, LastSnap] = Map::new()
  let records : Array[IRecord] = []
  let interval_ms = (cfg.interval * 1000.0).to_int64()
  let mut next = t0 + interval_ms
  while @async.now() < deadline {
    @async.sleep(25)
    drain(q, st)
    // Limits reached -> stop early like the senders do.
    let limit_hit =
      (cfg.num_bytes > 0L && total_bytes(st) >= cfg.num_bytes) ||
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
        if !(omitted) && !(cfg.json) {
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
  }
}

fn empty_stream() -> @ctl.StreamResult {
  {
    id: 5,
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

/// The iperf3 payload: a block filled with 'x' (0x78).
fn make_payload(blksize : Int) -> Bytes {
  Bytes::from_array(FixedArray::make(blksize, b'x'))
}

fn mget64(m : Map[Int, Int64], k : Int, d : Int64) -> Int64 {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}

fn mgetd(m : Map[Int, Double], k : Int, d : Double) -> Double {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}
fn mgetb(m : Map[Int, Bool], k : Int, d : Bool) -> Bool {
  match m.get(k) {
    Some(v) => v
    None => d
  }
}
