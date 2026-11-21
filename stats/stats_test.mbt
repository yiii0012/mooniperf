///|
/// Tests for the statistics package.
test "bitrate math" {
  assert_eq(@stats.bits_per_second(125000L, 1.0), 1000000.0)
  assert_eq(@stats.bits_per_second(1250000L, 10.0), 1000000.0)
  assert_eq(@stats.bits_per_second(1000L, 0.0), 0.0)
}

///|
test "snapshot deltas" {
  let a = @stats.Snapshot::new(0L, 0L, 0L)
  let b = @stats.Snapshot::new(1000L, 125000L, 10L)
  let d = @stats.Delta::between(a, b)
  assert_eq(d.seconds, 1.0)
  assert_eq(d.bytes, 125000L)
  assert_eq(d.packets, 10L)
  assert_eq(d.bits_per_second, 1000000.0)
  // Negative-duration windows yield zero bitrate instead of nonsense.
  let d2 = @stats.Delta::between(b, a)
  assert_eq(d2.bits_per_second, 0.0)
}

///|
test "UDP pacing targets track elapsed time and bitrate" {
  // 1 Mbit/s with 8 KiB datagrams: ~15.26 datagrams after 1 second.
  let t = @stats.target_datagrams(1000L, 1000000L, 8192)
  assert_true(t >= 15L && t <= 16L)
  // Unlimited bitrate means no pacing target.
  assert_eq(@stats.target_datagrams(1000L, 0L, 8192), 0L)
  // Per-datagram pacing interval at 1 Mbit/s, 8 KiB datagrams: 65.536 ms.
  let p = @stats.pacing_interval_ms(1000000L, 8192)
  assert_true(p > 65.0 && p < 66.0)
}

///|
test "RFC 1889 jitter estimator: constant spacing yields zero jitter" {
  // Datagrams every 10 ms exactly; transit identical every time.
  let r = @stats.UdpReceiver::new()
  let mut seq = 1L
  while seq <= 32L {
    r.on_datagram(seq, 0.005, 8192)
    seq += 1L
  }
  assert_eq(r.jitter, 0.0)
  assert_eq(r.cnt_error, 0L)
  assert_eq(r.packet_count, 32L)
}

///|
test "jitter estimator reacts to spacing variation like iperf3" {
  // Transit oscillates 0ms / 10ms; the first packet only initializes
  // prev_transit, then every |d| = 10ms is smoothed in with factor 1/16:
  // j_n = j_(n-1) * 15/16 + 10/16 -> after 3 deltas ~ 1.76 ms.
  let r = @stats.UdpReceiver::new()
  r.on_datagram(1L, 0.000, 1000)
  r.on_datagram(2L, 0.010, 1000)
  r.on_datagram(3L, 0.000, 1000)
  r.on_datagram(4L, 0.010, 1000)
  assert_true(r.jitter_ms() > 1.75 && r.jitter_ms() < 1.77)
}

///|
test "loss accounting charges gaps and credits reordering" {
  let r = @stats.UdpReceiver::new()
  r.on_datagram(1L, 0.0, 1000)
  // Jump from 1 to 5: datagrams 2,3,4 are lost.
  r.on_datagram(5L, 0.0, 1000)
  assert_eq(r.cnt_error, 3L)
  assert_eq(r.packet_count, 5L)
  // A backwards datagram (retransmission of 3) credits one loss back.
  r.on_datagram(3L, 0.0, 1000)
  assert_eq(r.out_of_order, 1L)
  assert_eq(r.cnt_error, 2L)
  // Continue normally.
  r.on_datagram(6L, 0.0, 1000)
  assert_eq(r.cnt_error, 2L)
  assert_eq(r.packet_count, 6L)
}

///|
test "omitted window keeps loss buckets apart" {
  let r = @stats.UdpReceiver::new()
  r.set_omitting(true)
  r.on_datagram(1L, 0.0, 1000)
  r.on_datagram(4L, 0.0, 1000) // 2 lost, charged to omitted bucket
  assert_eq(r.omitted_cnt_error, 2L)
  assert_eq(r.cnt_error, 0L)
  r.set_omitting(false)
  r.on_datagram(6L, 0.0, 1000) // 5 missing -> 1 lost in measured window
  assert_eq(r.cnt_error, 1L)
  // Bytes accounting counts whole datagrams (iperf3 semantics).
  assert_eq(r.bytes_received, 3000L)
  assert_eq(r.datagrams_received, 3L)
}

///|
test "receiver loss percentage" {
  let r = @stats.UdpReceiver::new()
  r.on_datagram(1L, 0.0, 1000)
  r.on_datagram(4L, 0.0, 1000) // 2 lost out of 4 seen
  assert_true(r.loss_percent() > 49.9 && r.loss_percent() < 50.1)
  assert_eq(@stats.UdpReceiver::new().loss_percent(), 0.0)
}

///|
test "target_datagrams survives the Int64 product overflow" {
  // 24 hours at 1 Tbit/s: elapsed*rate = 8.64e19 overflows Int64 (max
  // ~9.22e18). The guard must fall back to double math instead of wrapping
  // to a negative target (which would stall the pacer forever).
  let t = @stats.target_datagrams(86400000L, 1000000000000L, 8192)
  assert_true(t > 1000000000000L)
  assert_true(t > 0L)
  // Ordinary ranges are unaffected by the guard: 60 s at 1 Mbit/s with
  // 8 KiB datagrams is exactly floor(60e9 / 65.536e6) = 915 datagrams.
  assert_eq(@stats.target_datagrams(0L, 1000000L, 8192), 0L)
  assert_eq(@stats.target_datagrams(60000L, 1000000L, 8192), 915L)
}
