///|
/// Unit tests for the pure helpers of the control-channel I/O package
/// (`same_bytes`, `bytes_of`). The socket paths are exercised end-to-end by
/// the loopback smoke test in CI.
test "same_bytes: fixed-length comparison semantics" {
  assert_true(@wire.same_bytes(b"abc", b"abc"))
  assert_false(@wire.same_bytes(b"abc", b"abd"))
  // Length mismatch fails regardless of shared prefixes (cookie semantics).
  assert_false(@wire.same_bytes(b"abc", b"abcd"))
  assert_false(@wire.same_bytes(b"abcd", b"abc"))
  // The empty cookie compares equal to itself only.
  assert_true(@wire.same_bytes(b"", b""))
  assert_false(@wire.same_bytes(b"", b"a"))
}

///|
test "bytes_of: copies at most the buffer length" {
  let buf : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  buf[0] = b"a"[0]
  buf[1] = b"b"[0]
  buf[2] = b"c"[0]
  buf[3] = b"d"[0]
  // Full copy.
  assert_eq(@wire.bytes_of(buf, 4), b"abcd")
  // Partial copy takes the first len bytes.
  assert_eq(@wire.bytes_of(buf, 2), b"ab")
  // A request beyond the buffer clamps instead of panicking.
  assert_eq(@wire.bytes_of(buf, 99), b"abcd")
  // Zero-length reads yield empty bytes.
  assert_eq(@wire.bytes_of(buf, 0), b"")
}
