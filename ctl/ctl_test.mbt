///|
/// Unit tests for the wire-protocol codecs in `yiii0012/mooniperf/ctl`.
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

///|
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

///|
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

///|
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

///|
test "params parsing tolerates real-iperf3-style payloads with unknown fields" {
  let j = match
    @ctl.decode_json_message_opt(
      @utf8.encode(
        "{\"tcp\":true,\"udp\":false,\"omit\":0,\"server_affinity\":-1,\"time\":3,\"num\":0,\"blockcount\":0,\"MSS\":0,\"nodelay\":true,\"parallel\":4,\"reverse\":true,\"window\":0,\"len\":65536,\"bandwidth\":0,\"fqrate\":0,\"pacing_timer\":1000,\"burst\":0,\"get_server_output\":0,\"udp_counters_64bit\":0,\"repeating_payload\":0,\"zerocopy\":0,\"dont_fragment\":0,\"client_version\":\"iperf 3.17.1\"}",
      ),
    ) {
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

///|
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

///|
test "cookie is 37 bytes: 36 chars + NUL" {
  let c = @ctl.new_cookie()
  assert_eq(c.length(), 37)
  assert_eq(c[36], b"\x00"[0])
  // Charset is lowercase base32-like; no NUL may appear inside the body.
  let mut i = 0
  while i < 36 {
    assert_true(
      (c[i] >= b"a"[0] && c[i] <= b"z"[0]) ||
      (c[i] >= b"2"[0] && c[i] <= b"7"[0]),
    )
    i += 1
  }
  // Fresh cookies differ (extremely likely for 36 random chars).
  assert_true(c != @ctl.new_cookie())
}

///|
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

///|
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

///|
test "server error payload encodes two big-endian u32 words" {
  let payload = @ctl.encode_server_error(5, 111)
  assert_eq(payload.length(), 9)
  assert_eq(payload[0], b"\xfe"[0]) // SERVER_ERROR = -2
  let (i_errno, errno) = @ctl.decode_server_error(payload)
  assert_eq(i_errno, 5)
  assert_eq(errno, 111)
}

///|
test "server error body decodes the 8 bytes after the state byte" {
  // The wire layout is 1 state byte + 4-byte i_errno + 4-byte errno. A
  // reader that already consumed the state byte must decode the remaining
  // 8 bytes at offsets 0/4 (decode_server_error_body), not re-run the
  // 9-byte-frame decoder on a short payload.
  let buf : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  @ctl.put_u32_be(buf, 0, 5)
  @ctl.put_u32_be(buf, 4, 111)
  let body = Bytes::from_array(buf)
  let (i_errno, errno) = @ctl.decode_server_error_body(body)
  assert_eq(i_errno, 5)
  assert_eq(errno, 111)
  // The full-frame decoder agrees on the same message.
  let full = @ctl.encode_server_error(5, 111)
  let tail_buf : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  let mut i = 0
  while i < 8 {
    tail_buf[i] = full[i + 1]
    i += 1
  }
  let (i2, e2) = @ctl.decode_server_error_body(Bytes::from_array(tail_buf))
  assert_eq(i2, 5)
  assert_eq(e2, 111)
}

///|
test "params parsing clamps hostile values to safe ranges" {
  // len below the minimum header size or above 10 MiB is ignored.
  let j1 = @ctl.decode_json_message_opt(
    @utf8.encode("{\"udp\":true,\"len\":8,\"parallel\":0,\"time\":-5}"),
  )
  let p1 = match j1 {
    Some(x) => @ctl.Params::from_json(x)
    None => {
      assert_true(false)
      @ctl.Params::default_params()
    }
  }
  assert_eq(p1.blocksize(), 8192) // len=8 rejected -> UDP default
  assert_eq(p1.parallel, 1) // parallel=0 clamped to 1
  let j2 = @ctl.decode_json_message_opt(
    @utf8.encode("{\"len\":20971520,\"pacing_timer\":0}"),
  )
  let p2 = match j2 {
    Some(x) => @ctl.Params::from_json(x)
    None => {
      assert_true(false)
      @ctl.Params::default_params()
    }
  }
  assert_eq(p2.blocksize(), 131072) // len=20 MiB rejected -> TCP default
  assert_eq(p2.pacing_timer, 1000) // non-positive pacing timer rejected
}

///|
test "state byte is a signed char: 0x80 decodes to -128" {
  assert_eq(@ctl.state_from_byte(b"\x80"[0]), -128)
  assert_eq(@ctl.state_from_byte(b"\x7f"[0]), 127)
}

///|
test "MAX_PARAMS_JSON_LEN matches the iperf3 cap" {
  assert_eq(@ctl.MAX_PARAMS_JSON_LEN, 8192)
}

///|
test "stream ids follow iperf3's quirky iperf_add_stream sequence" {
  // iperf3 gives the first stream id 1 and every later stream k the id k+1
  // (its list walk starts the counter at 2), so the sequence is 1, 3, 4, 5...
  // Verified against iperf 3.1.3 on the wire: a -P 3 client announces ids
  // 1, 3, 4 in EXCHANGE_RESULTS.
  assert_eq(@ctl.stream_id(1), 1)
  assert_eq(@ctl.stream_id(2), 3)
  assert_eq(@ctl.stream_id(3), 4)
  assert_eq(@ctl.stream_id(4), 5)
  // Ordinals below 1 clamp to the first stream id instead of misbehaving.
  assert_eq(@ctl.stream_id(0), 1)
}

///|
test "results JSON carries server_output_text only when requested" {
  // Not requested -> empty string -> the key stays absent from the JSON,
  // exactly like iperf3's send_results.
  let r = @ctl.Results::single({
    id: 1,
    bytes: 1000L,
    retransmits: -1L,
    jitter: 0.0,
    errors: -1L,
    omitted_errors: 0L,
    packets: -1L,
    omitted_packets: 0L,
    start_time: 0.0,
    end_time: 5.0,
  })
  assert_eq(r.server_output_text, "")
  assert_false(r.to_json().stringify().contains("server_output_text"))
  // Requested -> the text round-trips through to_json/from_json.
  let r2 : @ctl.Results = { ..r, server_output_text: "server summary\n", }
  let text = r2.to_json().stringify()
  assert_true(text.contains("\"server_output_text\""))
  let j = match @ctl.decode_json_message_opt(@utf8.encode(text)) {
    Some(x) => x
    None => {
      assert_true(false)
      @ctl.jobj([])
    }
  }
  let back = @ctl.Results::from_json(j)
  assert_eq(back.server_output_text, "server summary\n")
  // A peer payload without the key falls back to "" instead of failing.
  let bare = @ctl.decode_json_message_opt(
    @utf8.encode("{\"cpu_util_total\":0.0,\"streams\":[]}"),
  )
  match bare {
    Some(x) => assert_eq(@ctl.Results::from_json(x).server_output_text, "")
    None => assert_true(false)
  }
}

///|
test "params to_json sends get_server_output only when requested" {
  let p = @ctl.Params::default_params()
  assert_false(p.to_json().stringify().contains("get_server_output"))
  p.get_server_output = 1
  assert_true(p.to_json().stringify().contains("\"get_server_output\":1"))
}

///|
test "bitrate resolution mirrors iperf3 defaults and -b 0 semantics" {
  // UDP without an explicit rate falls back to iperf3's 1 Mbit/s default.
  assert_eq(@ctl.Params::default_params().bitrate(), 0L)
  let u = @ctl.Params::default_params()
  u.udp = true
  assert_eq(u.bitrate(), 1000000L)
  // An explicit positive rate wins for either protocol...
  u.bandwidth = 5000000L
  assert_eq(u.bitrate(), 5000000L)
  let t = @ctl.Params::default_params()
  t.bandwidth = 5000000L
  assert_eq(t.bitrate(), 5000000L)
  // ...while a bandwidth of 0 (the key is absent on the wire then) falls
  // back to the UDP default on the receiving side.
  u.bandwidth = 0L
  assert_eq(u.bitrate(), 1000000L)
  // total_seconds folds the omitted warm-up window into the deadline.
  t.omit = 2
  t.time = 5
  assert_eq(t.total_seconds(), 7)
}
