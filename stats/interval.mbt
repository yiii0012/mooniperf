/// Throughput interval accounting shared by client and server.

///|
/// Bitrate in bits per second for `bytes` transferred over `seconds`.
pub fn bits_per_second(bytes : Int64, seconds : Double) -> Double {
  if seconds <= 0.0 {
    return 0.0
  }
  bytes.to_double() * 8.0 / seconds
}

///|
/// A point-in-time counter snapshot (monotonic-ish clock in ms).
pub(all) struct Snapshot {
  t_ms : Int64
  bytes : Int64
  packets : Int64
}

///|
pub fn Snapshot::new(t_ms : Int64, bytes : Int64, packets : Int64) -> Snapshot {
  { t_ms, bytes, packets, }
}

///|
/// Aggregated delta between two snapshots.
pub(all) struct Delta {
  seconds : Double
  bytes : Int64
  packets : Int64
  bits_per_second : Double
}

///|
pub fn Delta::between(prev : Snapshot, cur : Snapshot) -> Delta {
  let seconds = (cur.t_ms - prev.t_ms).to_double() / 1000.0
  let bytes = cur.bytes - prev.bytes
  let packets = cur.packets - prev.packets
  { seconds, bytes, packets, bits_per_second: bits_per_second(bytes, seconds), }
}

///|
/// Total delta from test start to `cur`.
pub fn Delta::since(start : Snapshot, cur : Snapshot) -> Delta {
  Delta::between(start, cur)
}

///|
/// Number of datagrams the sender should have emitted by `elapsed_ms` for a
/// target bitrate. Used for time-driven UDP pacing that works at any rate
/// without per-packet sleeps at high speeds.
pub fn target_datagrams(
  elapsed_ms : Int64,
  bitrate : Int64,
  datagram_size : Int32,
) -> Int64 {
  if bitrate <= 0L || datagram_size <= 0 {
    return 0L
  }
  let denom = 8L * 1000L * datagram_size.to_int64()
  // elapsed_ms * bitrate / denom, in 64-bit math. The product can overflow
  // for long tests at extreme rates (e.g. days at 1 Tbit/s); detect the wrap
  // and fall back to double math, clamped to the Int64 range.
  let num = elapsed_ms * bitrate
  if elapsed_ms > 0L && num / bitrate != elapsed_ms {
    let est = elapsed_ms.to_double() * bitrate.to_double() / denom.to_double()
    let max_i64 = 9223372036854775807L
    if est >= max_i64.to_double() {
      max_i64
    } else {
      est.to_int64()
    }
  } else {
    num / denom
  }
}

///|
/// Sleep interval in milliseconds between paced datagrams (>= 1 means
/// per-datagram pacing is meaningful).
pub fn pacing_interval_ms(bitrate : Int64, datagram_size : Int32) -> Double {
  if bitrate <= 0L || datagram_size <= 0 {
    return 0.0
  }
  datagram_size.to_double() * 8.0 * 1000.0 / bitrate.to_double()
}
