/// Unit tests for the wire-protocol codecs in `iyi/mooniperf/ctl`.
/// All values are cross-checked against iperf3's src/iperf_api.{h,c},
/// src/iperf_udp.c and the wire captures documented in docs/protocol.md.

test "state bytes round-trip through the signed single-byte wire format" {
  let states = [
    @ctl.TEST_START,
    @ctl.TEST_RUNNING,
    @ctl.TEST_END,
    @ctl.PARAM_EXCHANGE,
    @ctl.CREATE_STREAMS,
    @ctl.SERVER_TERMINATE,
    @ctl.CLIENT_TERMINATE,
    @ctl.EXCHANGE_RESULTS,
    @ctl.DISPLAY_RESULTS,
    @ctl.IPERF_START,
    @ctl.IPERF_DONE,
    @ctl.ACCESS_DENIED,
    @ctl.SERVER_ERROR,
  ]
  for s in states {
    assert_eq(@ctl.state_from_byte(@ctl.state_to_byte(s)), s)
  }
  // Negative states are a single byte on the wire: -1 -> 0xFF, -2 -> 0xFE.
  assert_eq(@ctl.state_to_byte(-1), b"\xff"[0])
  assert_eq(@ctl.state_to_byte(-2), b"\xfe"[0])
}

test "u32/u64 big-endian helpers match htonl layout" {
  let buf : FixedArray[Byte] = FixedArray::make(12, b'\x00')
  @ctl.put_u32_be(buf, 0, 0x12345678)
  assert_eq(buf[0], b"\x12"[0])
  assert_eq(buf[1], b"\x34"[0])
  assert_eq(buf[2], b"\x56"[0])
  assert_eq(buf[3], b"\x78"[0])
  @ctl.put_u64_be(buf, 4, 1125899906842624L)
  // 1125899906842624 == 0x0004000000000000
  assert_eq(buf[4], b"\x00"[0])
  assert_eq(buf[5], b"\x04"[0])
  assert_eq(buf[11], b"\x00"[0])
  let raw = b"\x12\x34\x56\x78\x00\x04\x00\x00\x00\x00\x00\x00"
  assert_eq(@ctl.get_u32_be(raw, 0), 0x12345678)
  assert_eq(@ctl.get_u64_be(raw, 4), 1125899906842624L)
}

test "JSON message framing: 4-byte big-endian length prefix" {
  let bytes = @ctl.encode_json_text("{\"a\":1}")
  // Body is 7 bytes; prefix 0x00000007.
  assert_eq(bytes.length(), 11)
  assert_eq(@ctl.get_u32_be(bytes, 0), 7)
  // The text follows verbatim.
  assert_eq(bytes[4], b"{"[0])
  assert_eq(bytes[10], b"}"[0])
  // And it decodes back.
  let j = match @ctl.decode_json_message_opt(b"{\"a\":1}") {
    Some(x) => x
    None => {
      assert_true(false)
      @ctl.jobj([])
    }
  }
  assert_eq(j.stringify(), "{\"a\":1}")
}

test "params JSON round-trip and iperf3 field names" {
  let p = @ctl.Params::default_params()
  p.udp = true
  p.time = 5
  p.omit = 1
  p.bandwidth = 2000000L
  let j = p.to_json()
  let text = j.stringify()
  // iperf3 reads these exact keys in send_parameters/get_parameters.
  assert_true(text.contains("\"udp\":true"))
  assert_true(text.contains("\"time\":5"))
  assert_true(text.contains("\"omit\":1"))
  assert_true(text.contains("\"bandwidth\":2000000"))
  assert_true(text.contains("\"client_version\""))
  let back = @ctl.Params::from_json(j)
  assert_true(back.udp)
  assert_eq(back.time, 5)
  assert_eq(back.omit, 1)
  assert_eq(back.bandwidth, 2000000L)
}

test "params parsing tolerates real-iperf3-style payloads with unknown fields" {
  let j = match @ctl.decode_json_message_opt(@utf8.encode(
      "{\"tcp\":true,\"udp\":false,\"omit\":0,\"server_affinity\":-1,\"time\":3,\"num\":0,\"blockcount\":0,\"MSS\":0,\"nodelay\":true,\"parallel\":4,\"reverse\":true,\"window\":0,\"len\":65536,\"bandwidth\":0,\"fqrate\":0,\"pacing_timer\":1000,\"burst\":0,\"get_server_output\":0,\"udp_counters_64bit\":0,\"repeating_payload\":0,\"zerocopy\":0,\"dont_fragment\":0,\"client_version\":\"iperf 3.17.1\"}",
    )) {
    Some(x) => x
    None => {
      assert_true(false)
      @ctl.jobj([])
    }
  }
  let p = @ctl.Params::from_json(j)
  assert_true(p.tcp)
  assert_eq(p.time, 3)
  assert_eq(p.parallel, 4)
  assert_true(p.reverse)
  assert_eq(p.blocksize(), 65536)
  assert_eq(p.client_version, "iperf 3.17.1")
  assert_eq(p.total_seconds(), 3)
}

test "results JSON round-trip" {
  let r = @ctl.Results::single({
    id: 5,
    bytes: 123456789L,
    retransmits: -1L,
    jitter: 0.021,
    errors: 3L,
    omitted_errors: 1L,
    packets: 4242L,
    omitted_packets: 100L,
    start_time: 0.0,
    end_time: 10.0004,
  })
  let j = r.to_json()
  let text = j.stringify()
  assert_true(text.contains("\"cpu_util_total\""))
  assert_true(text.contains("\"sender_has_retransmits\""))
  assert_true(text.contains("\"bytes\":123456789"))
  assert_true(text.contains("\"jitter\":0.021"))
  let back = @ctl.Results::from_json(j)
  assert_eq(back.streams.length(), 1)
  let s = back.streams[0]
  assert_eq(s.id, 5)
  assert_eq(s.bytes, 123456789L)
  assert_eq(s.errors, 3L)
  assert_eq(s.packets, 4242L)
  assert_eq(s.end_time, 10.0004)
}

test "cookie is 37 bytes: 36 chars + NUL" {
  let c = @ctl.new_cookie()
  assert_eq(c.length(), 37)
  assert_eq(c[36], b"\x00"[0])
  // Charset is lowercase base32-like; no NUL may appear inside the body.
  let mut i = 0
  while i < 36 {
    assert_true((c[i] >= b"a"[0] && c[i] <= b"z"[0]) || (c[i] >= b"2"[0] && c[i] <= b"7"[0]))
    i += 1
  }
  // Fresh cookies differ (extremely likely for 36 random chars).
  assert_true(c != @ctl.new_cookie())
}

test "UDP connect handshake magic bytes match iperf3 native-endian words" {
  // On little-endian hosts iperf3 sends 0x36373839 as the bytes "9876"
  // and replies 0x39383736 as "6789".
  assert_eq(@ctl.udp_connect_msg(), b"9876")
  assert_eq(@ctl.udp_connect_reply(), b"6789")
  assert_true(@ctl.is_udp_connect_msg(b"9876"))
  assert_true(@ctl.is_udp_connect_msg(b"6789")) // big-endian hosts
  assert_true(@ctl.is_udp_connect_msg(b"\x15\xcd\x5b\x07")) // legacy LE
  assert_true(@ctl.is_udp_connect_reply(b"6789"))
  assert_true(@ctl.is_udp_connect_reply(b"9876"))
  assert_true(@ctl.is_udp_connect_reply(b"\xb1\x68\xde\x3a")) // legacy LE
  assert_false(@ctl.is_udp_connect_msg(b"zzzz"))
}

test "datagram header codec (12- and 16-byte variants)" {
  let h = @ctl.encode_datagram_header(1700000000, 123456, 4321)
  assert_eq(h.length(), 12)
  match @ctl.decode_datagram_header(h, false) {
    Some((sec, usec, pcount)) => {
      assert_eq(sec, 1700000000)
      assert_eq(usec, 123456)
      assert_eq(pcount, 4321L)
    }
    None => assert_true(false)
  }
  let h64 = @ctl.encode_datagram_header64(1700000000, 1, 99_999_999_999L)
  assert_eq(h64.length(), 16)
  match @ctl.decode_datagram_header(h64, true) {
    Some((sec64, usec64, pcount64)) => {
      assert_eq(sec64, 1700000000)
      assert_eq(usec64, 1)
      assert_eq(pcount64, 99_999_999_999L)
    }
    None => assert_true(false)
  }
  // Short payloads decode to None instead of panicking.
  assert_true(@ctl.decode_datagram_header(b"\x00\x00", false) is None)
}

test "server error payload encodes two big-endian u32 words" {
  let payload = @ctl.encode_server_error(5, 111)
  assert_eq(payload.length(), 9)
  assert_eq(payload[0], b"\xfe"[0]) // SERVER_ERROR = -2
  let (i_errno, errno) = @ctl.decode_server_error(payload)
  assert_eq(i_errno, 5)
  assert_eq(errno, 111)
}
