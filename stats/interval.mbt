/// Throughput interval accounting shared by client and server.

/// Bitrate in bits per second for `bytes` transferred over `seconds`.
pub fn bits_per_second(bytes : Int64, seconds : Double) -> Double {
  if seconds <= 0.0 {
    return 0.0
  }
  bytes.to_double() * 8.0 / seconds
}

/// A point-in-time counter snapshot (monotonic-ish clock in ms).
pub(all) struct Snapshot {
  t_ms : Int64
  bytes : Int64
  packets : Int64
}

pub fn Snapshot::new(t_ms : Int64, bytes : Int64, packets : Int64) -> Snapshot {
  { t_ms, bytes, packets }
}

/// Aggregated delta between two snapshots.
pub(all) struct Delta {
  seconds : Double
  bytes : Int64
  packets : Int64
  bits_per_second : Double
}

pub fn Delta::between(prev : Snapshot, cur : Snapshot) -> Delta {
  let seconds = (cur.t_ms - prev.t_ms).to_double() / 1000.0
  let bytes = cur.bytes - prev.bytes
  let packets = cur.packets - prev.packets
  {
    seconds,
    bytes,
    packets,
    bits_per_second: bits_per_second(bytes, seconds),
  }
}

/// Total delta from test start to `cur`.
pub fn Delta::since(start : Snapshot, cur : Snapshot) -> Delta {
  Delta::between(start, cur)
}

/// Number of datagrams the sender should have emitted by `elapsed_ms` for a
/// target bitrate. Used for time-driven UDP pacing that works at any rate
/// without per-packet sleeps at high speeds.
pub fn target_datagrams(
  elapsed_ms : Int64,
  bitrate : Int64,
  datagram_size : Int,
) -> Int64 {
  if bitrate <= 0L || datagram_size <= 0 {
    return 0L
  }
  // elapsed_ms * bitrate / 8000 / datagram_size, in 64-bit math.
  elapsed_ms * bitrate / (8L * 1000L * datagram_size.to_int64())
}

/// Sleep interval in milliseconds between paced datagrams (>= 1 means
/// per-datagram pacing is meaningful).
pub fn pacing_interval_ms(bitrate : Int64, datagram_size : Int) -> Double {
  if bitrate <= 0L || datagram_size <= 0 {
    return 0.0
  }
  datagram_size.to_double() * 8.0 * 1000.0 / bitrate.to_double()
}
