///|
/// mooniperf CLI: an iperf3-compatible network throughput measurement tool.
const USAGE : String = "Usage: mooniperf [-s | -c host] [options]\n\n  -s, --server           run in server mode\n  -c, --client <host>    run in client mode, connecting to <host>\n  -p, --port <n>         server port to listen on/connect to (default 5201)\n  -t, --time <n>         time in seconds to transmit for (default 10)\n  -i, --interval <n>     seconds between periodic reports (default 1)\n  -P, --parallel <n>     number of parallel client streams (default 1)\n  -R, --reverse          reverse mode (planned; not supported yet)\n  -u, --udp              use UDP rather than TCP\n  -b, --bitrate <n>[KMGT] target bitrate in bits/sec (UDP default 1M, 0 = unlimited; paces TCP too)\n  -l, --len <n>          length of buffer in bytes (TCP default 131072, UDP 8192)\n  -n, --bytes <n>        stop after n bytes\n  -k, --blockcount <n>   stop after n blocks\n  -O, --omit <n>         omit the first n seconds from results\n  -w, --window <n>       socket window size (accepted, not applied yet)\n  --get-server-output    receive the server's summary back (printed, or embedded in -J)\n  -J, --json             output in JSON format\n  -v, --version          show version information\n  -h, --help             show this message\n\nmooniperf is an iperf3-compatible tool written in pure MoonBit.\n"

///|
/// Shared numeric core of the unit parsers. iperf3 scans these values with
/// `sscanf("%lf%c")` (src/units.c), so fractional inputs like "-b 1.5M" are
/// valid; a K/M/G/T suffix (case-insensitive) scales the number, anything
/// else after the number is rejected. Values are truncated to Int64 like
/// iperf3's `(iperf_size_t)` cast; non-finite, negative or overflowing
/// inputs are rejected outright.
fn parse_unit(s : String, decimal : Bool) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let suffix = s[s.length() - 1:].to_owned()
  let k = if decimal { 1000L } else { 1024L }
  let (num, mul) : (String, Int64) = match suffix {
    "K" | "k" => (s[:s.length() - 1].to_owned(), k)
    "M" | "m" => (s[:s.length() - 1].to_owned(), k * k)
    "G" | "g" => (s[:s.length() - 1].to_owned(), k * k * k)
    "T" | "t" => (s[:s.length() - 1].to_owned(), k * k * k * k)
    _ => (s, 1L)
  }
  let v = match parse_double(num) {
    Some(v) => v
    None => return None
  }
  if v.is_nan() || v.is_inf() || v < 0.0 {
    return None
  }
  let scaled = v * mul.to_double()
  // 2^63 as a double: anything at or beyond it no longer fits Int64.
  if scaled >= 9223372036854775808.0 {
    return None
  }
  Some(scaled.to_int64())
}

///|
/// Parse "-b 10M" style bitrates: K/M/G/T are decimal (10^3) multipliers,
/// per iperf3's `unit_atof_rate` (src/units.c). Fractional rates are valid.
fn parse_rate(s : String) -> Int64? {
  parse_unit(s, true)
}

///|
/// Parse "-n 32M" / "-k 1.5M" / "-l 64K" style byte or block counts: K/M/G/T
/// are binary (2^10) multipliers, per iperf3's `unit_atoi` (src/units.c).
fn parse_bytes(s : String) -> Int64? {
  parse_unit(s, false)
}

///|
/// iperf3 rejects any two of -t/-n/-k together (IEENDCONDITIONS,
/// src/iperf_api.c). Returns the iperf3 error message, or None when the
/// combination is valid.
fn end_condition_error(
  time_set : Bool,
  bytes_set : Bool,
  blocks_set : Bool,
) -> String? {
  let n = (if time_set { 1 } else { 0 }) +
    (if bytes_set { 1 } else { 0 }) +
    (if blocks_set { 1 } else { 0 })
  if n > 1 {
    Some("only one test end condition (-t, -n, -k) may be specified")
  } else {
    None
  }
}

///|
/// Parse a plain integer (bytes, blocks, seconds...).
fn parse_int(s : String) -> Int32? {
  match (Ok(@string.parse_int(s)) catch { e => Err(e) }) {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
fn parse_double(s : String) -> Double? {
  match (Ok(@string.parse_double(s)) catch { e => Err(e) }) {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
/// Report a CLI (argument-stage) error and exit with a non-zero code.
/// iperf3 prefixes these with "parameter error" (its main.c wraps
/// iperf_parse_arguments failures); in -J mode the message goes out as a
/// machine-readable {"error": ...} object instead of plain text + usage.
fn fail(json : Bool, msg : String) -> Int32 {
  if json {
    println(@ctl.jobj([("error", @ctl.jstr(msg))]).stringify())
  } else {
    println("iperf3: parameter error - \{msg}")
    println(USAGE)
  }
  1
}

///|
fn next_str(args : Array[String], i : Int32) -> (String, Int32)? {
  if i + 1 < args.length() {
    Some((args[i + 1], i + 1))
  } else {
    None
  }
}

///|
/// Read the next argument as an Int, returning it and the new index.
fn next_int(args : Array[String], i : Int32) -> (Int32, Int32)? {
  match next_str(args, i) {
    Some((s, ni)) =>
      match parse_int(s) {
        Some(v) => Some((v, ni))
        None => None
      }
    None => None
  }
}

///|
/// Read the next argument as a Double, returning it and the new index.
fn next_double(args : Array[String], i : Int32) -> (Double, Int32)? {
  match next_str(args, i) {
    Some((s, ni)) =>
      match parse_double(s) {
        Some(v) => Some((v, ni))
        None => None
      }
    None => None
  }
}

///|
/// Read the next argument as an Int64 with optional K/M/G suffix.
fn next_rate(args : Array[String], i : Int32) -> (Int64, Int32)? {
  match next_str(args, i) {
    Some((s, ni)) =>
      match parse_rate(s) {
        Some(v) => Some((v, ni))
        None => None
      }
    None => None
  }
}

///|
/// Read the next argument as a byte/block count with optional K/M/G/T
/// suffix (binary multipliers, like iperf3's -n/-k/-l/-w).
fn next_bytes(args : Array[String], i : Int32) -> (Int64, Int32)? {
  match next_str(args, i) {
    Some((s, ni)) =>
      match parse_bytes(s) {
        Some(v) => Some((v, ni))
        None => None
      }
    None => None
  }
}

///|
async fn main {
  let args = @env.args()
  let mut server_mode = false
  let mut client_mode = false
  let mut host = ""
  let mut port = 5201
  let mut time = 10
  let mut interval = 1.0
  let mut parallel = 1
  let mut udp = false
  // -1 = not given (iperf3 defaults); 0 = unlimited; >0 = target bits/s.
  let mut bandwidth : Int64 = -1L
  let mut blksize = 0
  let mut num_bytes : Int64 = 0L
  let mut blockcount : Int64 = 0L
  let mut omit = 0
  let mut window = 0
  let mut get_server_output = false
  let mut json = false
  // Which end conditions (-t/-n/-k) were given explicitly: at most one may
  // be set (iperf3 IEENDCONDITIONS).
  let mut time_set = false
  let mut bytes_set = false
  let mut blocks_set = false
  let mut bad : String? = None
  // argv[0] on native targets is the executable path; skip leading non-flag args.
  let mut i = 0
  if args.length() > 0 && args[0][:1].to_owned() != "-" {
    i = 1
  }
  while i < args.length() {
    let a = args[i]
    if a == "-s" || a == "--server" {
      server_mode = true
    } else if a == "-c" || a == "--client" {
      client_mode = true
      match next_str(args, i) {
        Some((h, ni)) => {
          host = h
          i = ni
        }
        None => bad = Some("-c requires a host argument")
      }
    } else if a == "-p" || a == "--port" {
      match next_int(args, i) {
        Some((v, ni)) => {
          port = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-t" || a == "--time" {
      match next_int(args, i) {
        Some((v, ni)) => {
          time = v
          time_set = true
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-i" || a == "--interval" {
      match next_double(args, i) {
        Some((v, ni)) => {
          interval = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-P" || a == "--parallel" {
      match next_int(args, i) {
        Some((v, ni)) => {
          parallel = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-R" || a == "--reverse" {
      bad = Some(
        "reverse mode (-R) is not supported yet; see docs/roadmap.md in the repository",
      )
    } else if a == "-u" || a == "--udp" {
      udp = true
    } else if a == "-b" || a == "--bitrate" {
      match next_rate(args, i) {
        Some((v, ni)) => {
          bandwidth = v
          i = ni
        }
        None => bad = Some("-b requires a rate like 10M")
      }
    } else if a == "-l" || a == "--len" {
      match next_bytes(args, i) {
        Some((v, ni)) => {
          blksize = v.to_int()
          i = ni
        }
        None => bad = Some("\{a} requires a size like 131072 or 128K")
      }
    } else if a == "-n" || a == "--bytes" {
      match next_bytes(args, i) {
        Some((v, ni)) => {
          num_bytes = v
          bytes_set = true
          i = ni
        }
        None => bad = Some("\{a} requires a size like 100M")
      }
    } else if a == "-k" || a == "--blockcount" {
      match next_bytes(args, i) {
        Some((v, ni)) => {
          blockcount = v
          blocks_set = true
          i = ni
        }
        None => bad = Some("\{a} requires a block count like 1000M")
      }
    } else if a == "-O" || a == "--omit" {
      match next_int(args, i) {
        Some((v, ni)) => {
          omit = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-w" || a == "--window" {
      match next_bytes(args, i) {
        Some((v, ni)) => {
          window = v.to_int()
          i = ni
        }
        None => bad = Some("\{a} requires a size like 1M")
      }
    } else if a == "--get-server-output" {
      get_server_output = true
    } else if a == "-J" || a == "--json" {
      json = true
    } else if a == "-v" || a == "--version" {
      println("mooniperf \{@client.VERSION} (MoonBit)")
      println("iperf3 wire protocol compatible")
      return
    } else if a == "-h" || a == "--help" {
      println(USAGE)
      return
    } else {
      bad = Some("unknown option \{a}")
    }
    i += 1
  }
  // Argument errors must leave a NON-ZERO exit code on stderr semantics,
  // like iperf3 (probed 2026-11-22: bare `return` exited 0).
  match bad {
    Some(msg) => @env.exit(fail(json, msg))
    None => ()
  }
  if !(server_mode || client_mode) {
    @env.exit(fail(json, "must either be a client (-c) or server (-s)"))
  }
  if server_mode && client_mode {
    @env.exit(fail(json, "cannot be both a client and a server"))
  }
  if port < 1 || port > 65535 {
    @env.exit(fail(json, "port (-p) must be between 1 and 65535"))
  }
  if server_mode {
    @env.exit(@server.run_server(port))
  }
  if parallel < 1 || parallel > 128 {
    @env.exit(fail(json, "parallel streams must be between 1 and 128"))
  }
  // iperf3 caps -t at MAX_TIME (86400); negative durations are rejected too.
  if time < 1 {
    @env.exit(fail(json, "test duration must be at least 1 second"))
  }
  if time > 86400 {
    @env.exit(fail(json, "test duration too long (maximum = 86400 seconds)"))
  }
  // Only one of -t/-n/-k may end the test (iperf3 IEENDCONDITIONS).
  match end_condition_error(time_set, bytes_set, blocks_set) {
    Some(msg) => @env.exit(fail(json, msg))
    None => ()
  }
  // -i 0 would stall the periodic reporter (its next-report pointer never
  // advances), and -l below the 12-byte UDP datagram header would write out
  // of bounds — both rejected up front instead.
  if interval <= 0.0 {
    @env.exit(fail(json, "report interval (-i) must be positive"))
  }
  if omit < 0 {
    @env.exit(fail(json, "omit seconds (-O) must not be negative"))
  }
  if blksize < 0 || blksize > 10 * 1024 * 1024 {
    @env.exit(
      fail(json, "block size (-l) must be between 1 and 10485760 bytes"),
    )
  }
  if udp && blksize > 0 && blksize < @ctl.DATAGRAM_HEADER_SIZE {
    @env.exit(
      fail(
        json,
        "UDP block size (-l) must be at least \{@ctl.DATAGRAM_HEADER_SIZE} bytes",
      ),
    )
  }
  if udp && parallel > 1 {
    println(
      "note: UDP mode uses a single stream in v0.1; ignoring -P \{parallel}",
    )
    parallel = 1
  }
  let cfg : @client.ClientConfig = {
    host,
    port,
    time,
    omit,
    interval,
    parallel,
    reverse: false,
    udp,
    bandwidth,
    blksize,
    num_bytes,
    blockcount,
    window,
    get_server_output,
    json,
  }
  let code = @client.run_client(cfg)
  @env.exit(code)
}
