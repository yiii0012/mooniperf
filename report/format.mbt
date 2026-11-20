/// Output formatting shared by client and server: iperf3-style human text
/// and an iperf3-compatible `--json` report structure.

/// Humanize a byte count the way iperf3's adaptive format does
/// (1024-based KBytes/MBytes/GBytes, 2 decimal places above 10 units).
pub fn fmt_bytes(n : Int64) -> String {
  if n <= 0L {
    return "0.00 Bytes"
  }
  let mut v = n.to_double()
  let units = ["Bytes", "KBytes", "MBytes", "GBytes", "TBytes"]
  let mut u = 0
  while v >= 1024.0 && u < units.length() - 1 {
    v = v / 1024.0
    u += 1
  }
  let digits = if v >= 100.0 { 0 } else if v >= 10.0 { 1 } else { 2 }
  fixed(v, digits) + " " + units[u]
}

/// Humanize a bitrate (1000-based bits/Kbits/Mbits/Gbits, iperf3 style).
pub fn fmt_bps(bps : Double) -> String {
  if bps <= 0.0 {
    return "0.00 bits/sec"
  }
  let units = ["bits/sec", "Kbits/sec", "Mbits/sec", "Gbits/sec", "Tbits/sec"]
  let mut v = bps
  let mut u = 0
  while v >= 1000.0 && u < units.length() - 1 {
    v = v / 1000.0
    u += 1
  }
  let digits = if v >= 100.0 { 0 } else if v >= 10.0 { 1 } else { 2 }
  fixed(v, digits) + " " + units[u]
}

/// Format a Double with `digits` decimal places (no scientific notation).
pub fn fixed(v : Double, digits : Int) -> String {
  let neg = v < 0.0
  let a = if neg { -v } else { v }
  let mut scale : Int64 = 1
  let mut i = 0
  while i < digits {
    scale *= 10L
    i += 1
  }
  // Round half away from zero to avoid double repr surprises.
  let scaled = (a * scale.to_double() + 0.5).to_int64()
  let whole = scaled / scale
  let frac = scaled % scale
  let sb = StringBuilder()
  if neg {
    sb.write_string("-")
  }
  sb.write_string(whole.to_string())
  if digits > 0 {
    sb.write_string(".")
    let mut fs = frac.to_string()
    // Left-pad the fractional digits, e.g. 5 -> "05" for 2 digits.
    while fs.length() < digits {
      fs = "0" + fs
    }
    sb.write_string(fs)
  }
  sb.to_string()
}

/// Pad `s` on the left with spaces to width `w` (iperf3 column layout).
pub fn pad_left(s : String, w : Int) -> String {
  let sb = StringBuilder()
  let mut i = s.length()
  while i < w {
    sb.write_string(" ")
    i += 1
  }
  sb.write_string(s)
  sb.to_string()
}

/// Pad `s` on the right with spaces to width `w`.
pub fn pad_right(s : String, w : Int) -> String {
  let sb = StringBuilder()
  sb.write_string(s)
  let mut i = s.length()
  while i < w {
    sb.write_string(" ")
    i += 1
  }
  sb.to_string()
}

/// `[  5]   0.00-1.00   sec  ...` — the iperf3 interval prefix.
pub fn interval_prefix(socket : Int, start : Double, end : Double) -> String {
  let sb = StringBuilder()
  sb.write_string(pad_left(socket.to_string(), 5))
  sb.write_string("  ")
  sb.write_string(pad_right(pad_left(fixed(start, 2), 5) + "-" + fixed(end, 2), 12))
  sb.write_string("  sec  ")
  sb.to_string()
}
