/// iperf3 PARAM_EXCHANGE parameters (the JSON sent by the client right after
/// the server's PARAM_EXCHANGE state byte). Field names mirror iperf3's
/// `send_parameters()` in src/iperf_api.c; unset/optional values of the
/// original are folded into sensible defaults here.

/// iperf3 default block sizes.
pub const DEFAULT_TCP_BLKSIZE : Int = 131072
pub const DEFAULT_UDP_BLKSIZE : Int = 8192
/// iperf3 default UDP send rate (-b), 1 Mbit/s.
pub const DEFAULT_UDP_BANDWIDTH : Int64 = 1000000L
/// iperf3 default pacing timer granularity (ms).
pub const DEFAULT_PACING_TIMER : Int = 1000

pub(all) struct Params {
  mut tcp : Bool
  mut udp : Bool
  /// Seconds to omit from results (-O).
  mut omit : Int
  /// Test duration in seconds (-t).
  mut time : Int
  /// Byte limit (-n), 0 = unlimited.
  mut num : Int64
  /// Block count limit (-k), 0 = unlimited.
  mut blockcount : Int64
  /// Number of parallel streams (-P).
  mut parallel : Int
  /// Reverse mode (-R): server sends, client receives.
  mut reverse : Bool
  /// Socket window size (-w); 0 = system default.
  mut window : Int
  /// Block size (-l); 0 = resolve by protocol.
  mut len : Int
  /// UDP target bitrate in bits/s (-b); 0 = iperf3 default 1 Mbit/s.
  mut bandwidth : Int64
  /// Pacing timer granularity in ms.
  mut pacing_timer : Int
  /// --get-server-output flag.
  mut get_server_output : Int
  /// 64-bit UDP sequence counters flag.
  mut udp_counters_64bit : Int
  /// Version string of the sending client (newer iperf3 sends this).
  mut client_version : String
}

/// Resolve the effective block size for this test.
pub fn Params::blocksize(self : Params) -> Int {
  let l = self.len
  if l > 0 {
    l
  } else if self.udp {
    DEFAULT_UDP_BLKSIZE
  } else {
    DEFAULT_TCP_BLKSIZE
  }
}

/// Resolve the effective UDP bitrate.
pub fn Params::bitrate(self : Params) -> Int64 {
  if self.bandwidth > 0L {
    self.bandwidth
  } else if self.udp {
    DEFAULT_UDP_BANDWIDTH
  } else {
    0L
  }
}

/// Test duration including the omitted warm-up window.
pub fn Params::total_seconds(self : Params) -> Int {
  self.omit + self.time
}

/// Serialize into the PARAM_EXCHANGE JSON object.
pub fn Params::to_json(self : Params) -> @json.Json {
  jobj([
    ("tcp", jbool(self.tcp)),
    ("udp", jbool(self.udp)),
    ("omit", jnum(self.omit.to_double())),
    ("time", jnum(self.time.to_double())),
    ("num", jnum64(self.num)),
    ("blockcount", jnum64(self.blockcount)),
    ("parallel", jnum(self.parallel.to_double())),
    ("reverse", jbool(self.reverse)),
    ("window", jnum(self.window.to_double())),
    ("len", jnum(self.blocksize().to_double())),
    ("bandwidth", jnum64(self.bandwidth)),
    ("pacing_timer", jnum(self.pacing_timer.to_double())),
    ("get_server_output", jnum(self.get_server_output.to_double())),
    ("udp_counters_64bit", jnum(self.udp_counters_64bit.to_double())),
    ("client_version", jstr(self.client_version)),
  ])
}

/// Parse a PARAM_EXCHANGE JSON object (as sent by a real iperf3 client).
/// Unknown fields are ignored; missing fields fall back to iperf3 defaults.
pub fn Params::from_json(j : @json.Json) -> Params {
  let d = Params::default_params()
  if j is { "tcp": b, .. } {
    match jbool_of(b) {
      Some(t) => { d.tcp = t; d.udp = not(t) }
      None => ()
    }
  }
  if j is { "udp": b, .. } {
    match jbool_of(b) {
      Some(u) => {
        d.udp = u
        d.tcp = not(u)
      }
      None => ()
    }
  }
  if j is { "omit": Number(v, ..) } {
    d.omit = v.to_int()
  }
  if j is { "time": Number(v, ..) } {
    d.time = v.to_int()
  }
  if j is { "num": Number(v, ..) } {
    d.num = v.to_int64()
  }
  if j is { "blockcount": Number(v, ..) } {
    d.blockcount = v.to_int64()
  }
  if j is { "parallel": Number(v, ..) } {
    let p = v.to_int()
    d.parallel = if p < 1 { 1 } else { p }
  }
  if j is { "reverse": b, .. } {
    match jbool_of(b) {
      Some(r) => d.reverse = r
      None => ()
    }
  }
  // "bidirectional" is not supported yet; treated as plain forward mode.
  if j is { "window": Number(v, ..) } {
    d.window = v.to_int()
  }
  if j is { "len": Number(v, ..) } {
    let l = v.to_int()
    if l >= 12 && l <= 10 * 1024 * 1024 {
      d.len = l
    }
  }
  if j is { "bandwidth": Number(v, ..) } {
    d.bandwidth = v.to_int64()
  }
  if j is { "pacing_timer": Number(v, ..) } {
    let p = v.to_int()
    if p > 0 {
      d.pacing_timer = p
    }
  }
  if j is { "get_server_output": Number(v, ..) } {
    d.get_server_output = v.to_int()
  }
  if j is { "udp_counters_64bit": Number(v, ..) } {
    d.udp_counters_64bit = v.to_int()
  }
  if j is { "client_version": String(s), .. } {
    d.client_version = s
  }
  d
}

/// iperf3-compatible defaults for a TCP, 10 s, single-stream forward test.
pub fn Params::default_params() -> Params {
  {
    tcp: true,
    udp: false,
    omit: 0,
    time: 10,
    num: 0L,
    blockcount: 0L,
    parallel: 1,
    reverse: false,
    window: 0,
    len: 0,
    bandwidth: 0L,
    pacing_timer: DEFAULT_PACING_TIMER,
    get_server_output: 0,
    udp_counters_64bit: 0,
    client_version: "",
  }
}
