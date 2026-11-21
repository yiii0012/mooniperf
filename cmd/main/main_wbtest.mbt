///|
/// Boundary tests for CLI value parsing (private helpers of the executable).
test "parse_rate: K/M/G/T suffixes, both cases" {
  assert_eq(parse_rate("10M"), Some(10000000L))
  assert_eq(parse_rate("2m"), Some(2000000L))
  assert_eq(parse_rate("1G"), Some(1000000000L))
  assert_eq(parse_rate("500K"), Some(500000L))
  assert_eq(parse_rate("1t"), Some(1000000000000L))
  // Plain numbers pass through unscaled; zero is a valid rate.
  assert_eq(parse_rate("1234"), Some(1234L))
  assert_eq(parse_rate("0"), Some(0L))
}

///|
test "parse_rate: rejects malformed and out-of-range input" {
  assert_eq(parse_rate(""), None)
  assert_eq(parse_rate("abc"), None)
  // Fractional rates are not accepted (iperf3's kmg_to_bits is integer).
  assert_eq(parse_rate("1.5M"), None)
  // Beyond Int64 range fails cleanly instead of wrapping.
  assert_eq(parse_rate("99999999999999999999"), None)
  // A lone suffix letter is not a number.
  assert_eq(parse_rate("M"), None)
}
