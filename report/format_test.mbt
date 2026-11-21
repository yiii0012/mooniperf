///|
/// Tests for iperf3-style formatting.
test "fixed formatting with rounding and padding" {
  assert_eq(@report.fixed(1.0, 2), "1.00")
  assert_eq(@report.fixed(9.416, 2), "9.42")
  assert_eq(@report.fixed(938.4, 1), "938.4")
  assert_eq(@report.fixed(0.05, 3), "0.050")
  assert_eq(@report.fixed(-2.5, 0), "-3")
  assert_eq(@report.fixed(0.0, 2), "0.00")
  assert_eq(@report.fixed(1234.567, 4), "1234.5670")
}

///|
test "byte humanization is 1024-based like iperf3" {
  assert_eq(@report.fmt_bytes(125000L), "122 KBytes")
  // ~1.18e9 bytes is the "1.10 GBytes" of a 10 s 945 Mbit/s run.
  assert_eq(@report.fmt_bytes(1181938688L), "1.10 GBytes")
  assert_eq(@report.fmt_bytes(999L), "999 Bytes")
  assert_eq(@report.fmt_bytes(0L), "0.00 Bytes")
}

///|
test "bitrate humanization is 1000-based like iperf3" {
  assert_eq(@report.fmt_bps(1000000.0), "1.00 Mbits/sec")
  assert_eq(@report.fmt_bps(945600000.0), "946 Mbits/sec")
  assert_eq(@report.fmt_bps(1024.0), "1.02 Kbits/sec")
  assert_eq(@report.fmt_bps(0.0), "0.00 bits/sec")
}

///|
test "column padding and interval prefix" {
  assert_eq(@report.pad_left("5", 3), "  5")
  assert_eq(@report.pad_right("sec", 6), "sec   ")
  let line = @report.interval_prefix(5, 0.0, 1.0)
  assert_true(line.contains("5"))
  assert_true(line.contains("0.00-1.00"))
  assert_true(line.contains("sec"))
}
