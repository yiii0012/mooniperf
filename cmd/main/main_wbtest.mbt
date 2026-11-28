///|
/// Boundary tests for CLI value parsing (private helpers of the executable).
/// Parsing mirrors iperf3's src/units.c: -b uses decimal (10^3) suffixes via
/// unit_atof_rate; -n/-k/-l/-w use binary (2^10) suffixes via unit_atoi;
/// both accept fractional numbers (sscanf "%lf") and truncate to Int64.
test "parse_rate: decimal suffixes, both cases, fractional values" {
  assert_eq(parse_rate("10M"), Some(10000000L))
  assert_eq(parse_rate("2m"), Some(2000000L))
  assert_eq(parse_rate("1G"), Some(1000000000L))
  assert_eq(parse_rate("500K"), Some(500000L))
  assert_eq(parse_rate("1t"), Some(1000000000000L))
  // Fractional rates are valid, like iperf3's sscanf("%lf") parse.
  assert_eq(parse_rate("1.5M"), Some(1500000L))
  assert_eq(parse_rate("0.5K"), Some(500L))
  // Plain numbers pass through unscaled; zero is a valid rate.
  assert_eq(parse_rate("1234"), Some(1234L))
  assert_eq(parse_rate("0"), Some(0L))
  // Truncation to Int64, like iperf3's (iperf_size_t) cast.
  assert_eq(parse_rate("1.9"), Some(1L))
}

///|
test "parse_bytes: binary suffixes per iperf3's unit_atoi" {
  assert_eq(parse_bytes("32M"), Some(33554432L))
  assert_eq(parse_bytes("1K"), Some(1024L))
  assert_eq(parse_bytes("128k"), Some(131072L))
  assert_eq(parse_bytes("1G"), Some(1073741824L))
  // Fractional counts are valid and truncate.
  assert_eq(parse_bytes("1.5M"), Some(1572864L))
  assert_eq(parse_bytes("2.5K"), Some(2560L))
  assert_eq(parse_bytes("64"), Some(64L))
  // Decimal and binary bases differ: 1Mb of bitrate vs 1MB of bytes.
  assert_true(parse_bytes("1M").unwrap() != parse_rate("1M").unwrap())
}

///|
test "parse_rate: rejects malformed and out-of-range input" {
  assert_eq(parse_rate(""), None)
  assert_eq(parse_rate("abc"), None)
  // A lone suffix letter is not a number.
  assert_eq(parse_rate("M"), None)
  // Negative rates are rejected.
  assert_eq(parse_rate("-10M"), None)
  // Beyond Int64 range fails cleanly instead of wrapping.
  assert_eq(parse_rate("99999999999999999999"), None)
  assert_eq(parse_rate("99999999T"), None)
}

///|
test "parse_bytes: rejects malformed and out-of-range input" {
  assert_eq(parse_bytes(""), None)
  assert_eq(parse_bytes("abc"), None)
  assert_eq(parse_bytes("K"), None)
  assert_eq(parse_bytes("-1M"), None)
  assert_eq(parse_bytes("99999999999999999999"), None)
  assert_eq(parse_bytes("99999999T"), None)
}

///|
test "end_condition_error: at most one of -t/-n/-k (iperf3 IEENDCONDITIONS)" {
  // Single end conditions are fine.
  assert_true(end_condition_error(true, false, false) is None)
  assert_true(end_condition_error(false, true, false) is None)
  assert_true(end_condition_error(false, false, true) is None)
  assert_true(end_condition_error(false, false, false) is None)
  // Any two together are rejected with iperf3's exact message.
  match end_condition_error(true, true, false) {
    Some(msg) =>
      assert_eq(
        msg, "only one test end condition (-t, -n, -k) may be specified",
      )
    None => assert_true(false)
  }
  assert_true(end_condition_error(true, false, true) is Some(_))
  assert_true(end_condition_error(false, true, true) is Some(_))
  assert_true(end_condition_error(true, true, true) is Some(_))
}
