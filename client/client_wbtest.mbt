///|
/// Boundary tests for client-side helpers (private to this package).
test "split_limit: totals are split per stream, at least 1 each" {
  assert_eq(split_limit(0L, 4), 0L)
  assert_eq(split_limit(10L, 4), 2L)
  assert_eq(split_limit(2L, 4), 1L)
  assert_eq(split_limit(1L, 1), 1L)
  // Stream count below 1 is clamped instead of dividing by zero.
  assert_eq(split_limit(10L, 0), 10L)
}

///|
test "effective_blksize: explicit -l wins, else protocol default" {
  let base : ClientConfig = {
    host: "",
    port: 5201,
    time: 10,
    omit: 0,
    interval: 1.0,
    parallel: 1,
    reverse: false,
    udp: false,
    bandwidth: 0L,
    blksize: 0,
    num_bytes: 0L,
    blockcount: 0L,
    window: 0,
    json: false,
  }
  assert_eq(effective_blksize(base), 131072)
  assert_eq(effective_blksize({ ..base, udp: true, }), 8192)
  assert_eq(effective_blksize({ ..base, blksize: 65536, }), 65536)
  assert_eq(effective_blksize({ ..base, udp: true, blksize: 4096, }), 4096)
}

///|
test "stamp_datagram patches the 12-byte iperf3 UDP header in place" {
  let buf : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  // 1700000000 s + 500 ms; sequence 7.
  stamp_datagram(buf, 1700000000500L, 7L)
  assert_eq(@ctl.get_u32_be(@wire.bytes_of(buf, 12), 0), 1700000000)
  assert_eq(@ctl.get_u32_be(@wire.bytes_of(buf, 12), 4), 500000)
  assert_eq(@ctl.get_u32_be(@wire.bytes_of(buf, 12), 8), 7)
  // Milliseconds beyond the second roll over correctly.
  stamp_datagram(buf, 1700000000999L, 1L)
  assert_eq(@ctl.get_u32_be(@wire.bytes_of(buf, 12), 0), 1700000000)
  assert_eq(@ctl.get_u32_be(@wire.bytes_of(buf, 12), 4), 999000)
}
