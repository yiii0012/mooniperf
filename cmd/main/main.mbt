///|
/// mooniperf CLI: an iperf3-compatible network throughput measurement tool.
const USAGE : String = "Usage: mooniperf [-s | -c host] [options]\n\n  -s, --server           run in server mode\n  -c, --client <host>    run in client mode, connecting to <host>\n  -p, --port <n>         server port to listen on/connect to (default 5201)\n  -t, --time <n>         time in seconds to transmit for (default 10)\n  -i, --interval <n>     seconds between periodic reports (default 1)\n  -P, --parallel <n>     number of parallel client streams (default 1)\n  -R, --reverse          reverse mode (planned; not supported yet)\n  -u, --udp              use UDP rather than TCP\n  -b, --bitrate <n>[KMGT] target bitrate in bits/sec (UDP default 1M, TCP unlimited)\n  -l, --len <n>          length of buffer in bytes (TCP default 131072, UDP 8192)\n  -n, --bytes <n>        stop after n bytes\n  -k, --blockcount <n>   stop after n blocks\n  -O, --omit <n>         omit the first n seconds from results\n  -w, --window <n>       socket window size (accepted, not applied yet)\n  -J, --json             output in JSON format\n  -v, --version          show version information\n  -h, --help             show this message\n\nmooniperf is an iperf3-compatible tool written in pure MoonBit.\n"

///|
/// Parse "-b 10M" style values: plain numbers or K/M/G suffixes (bits).
fn parse_rate(s : String) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let suffix = s[s.length() - 1:].to_owned()
  let (num, mul) = match suffix {
    "K" | "k" => (s[:s.length() - 1].to_owned(), 1000L)
    "M" | "m" => (s[:s.length() - 1].to_owned(), 1000000L)
    "G" | "g" => (s[:s.length() - 1].to_owned(), 1000000000L)
    "T" | "t" => (s[:s.length() - 1].to_owned(), 1000000000000L)
    _ => (s, 1L)
  }
  match (Ok(@string.parse_int64(num)) catch { e => Err(e) }) {
    Ok(v) => Some(v * mul)
    Err(_) => None
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
fn fail(msg : String) -> Int32 {
  println("iperf3: error - \{msg}")
  println(USAGE)
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
  let mut bandwidth : Int64 = 0L
  let mut blksize = 0
  let mut num_bytes : Int64 = 0L
  let mut blockcount : Int64 = 0L
  let mut omit = 0
  let mut window = 0
  let mut json = false
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
      match next_int(args, i) {
        Some((v, ni)) => {
          blksize = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-n" || a == "--bytes" {
      match next_rate(args, i) {
        Some((v, ni)) => {
          num_bytes = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
    } else if a == "-k" || a == "--blockcount" {
      match next_rate(args, i) {
        Some((v, ni)) => {
          blockcount = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
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
      match next_int(args, i) {
        Some((v, ni)) => {
          window = v
          i = ni
        }
        None => bad = Some("\{a} requires a number")
      }
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
  match bad {
    Some(msg) => {
      let _ = fail(msg)
      return
    }
    None => ()
  }
  if !(server_mode || client_mode) {
    let _ = fail("must either be a client (-c) or server (-s)")
    return
  }
  if server_mode && client_mode {
    let _ = fail("cannot be both a client and a server")
    return
  }
  if server_mode {
    let _ = @server.run_server(port)
    return
  }
  if parallel < 1 || parallel > 128 {
    let _ = fail("parallel streams must be between 1 and 128")
    return
  }
  if time < 1 {
    let _ = fail("test duration must be at least 1 second")
    return
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
    json,
  }
  let code = @client.run_client(cfg)
  @env.exit(code)
}
