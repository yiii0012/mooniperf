/// iperf3 UDP wire bits: the connection handshake datagrams and the 12-byte
/// per-datagram header used for jitter and loss accounting (src/iperf_udp.c).

/// Header size in bytes when 32-bit sequence counters are used.
pub const DATAGRAM_HEADER_SIZE : Int = 12
/// Header size when udp_counters_64bit is negotiated.
pub const DATAGRAM_HEADER_SIZE_64 : Int = 16

/// iperf3's UDP handshake uses native-byte-order u32 words. All MoonBit
/// native targets are little-endian, so the on-wire bytes are the LE
/// encodings (matching iperf3 on x86/ARM, the platforms it is deployed on).
/// The values spell out "9876" / "6789" on little-endian machines.

/// Client -> server first datagram (u32 0x36373839, little-endian bytes).
pub fn udp_connect_msg() -> Bytes {
  b"\x39\x38\x37\x36"
}

/// Server -> client handshake reply (u32 0x39383736, little-endian bytes).
pub fn udp_connect_reply() -> Bytes {
  b"\x36\x37\x38\x39"
}

/// iperf2-era fallback message (123456789).
pub fn legacy_udp_connect_msg() -> Bytes {
  le_u32(123456789)
}

/// iperf2-era fallback reply (987654321).
pub fn legacy_udp_connect_reply() -> Bytes {
  le_u32(987654321)
}

/// Encode v in little-endian order.
fn le_u32(v : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  out[0] = (v & 0xFF).to_byte()
  out[1] = ((v >> 8) & 0xFF).to_byte()
  out[2] = ((v >> 16) & 0xFF).to_byte()
  out[3] = ((v >> 24) & 0xFF).to_byte()
  Bytes::from_array(out)
}

/// Encode v in big-endian order.
fn be_u32(v : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  out[0] = ((v >> 24) & 0xFF).to_byte()
  out[1] = ((v >> 16) & 0xFF).to_byte()
  out[2] = ((v >> 8) & 0xFF).to_byte()
  out[3] = (v & 0xFF).to_byte()
  Bytes::from_array(out)
}

fn eq4(a : Bytes, b : Bytes) -> Bool {
  a.length() >= 4 && b.length() == 4 && a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
}

/// Whether the datagram looks like a UDP connect request (accepts both byte
/// orders and the iperf2-era legacy value, like iperf3's tolerant handshake).
pub fn is_udp_connect_msg(b : Bytes) -> Bool {
  eq4(b, udp_connect_msg()) ||
  eq4(b, be_u32(0x36373839)) ||
  eq4(b, legacy_udp_connect_msg()) ||
  eq4(b, be_u32(123456789))
}

/// Whether the datagram looks like a UDP connect reply (both byte orders and
/// the legacy value).
pub fn is_udp_connect_reply(b : Bytes) -> Bool {
  eq4(b, udp_connect_reply()) ||
  eq4(b, be_u32(0x39383736)) ||
  eq4(b, legacy_udp_connect_reply()) ||
  eq4(b, be_u32(987654321))
}

/// Encode the 12-byte datagram header: seconds, microseconds, packet counter
/// — all 32-bit big-endian (iperf3 packs them with htonl).
pub fn encode_datagram_header(sec : Int, usec : Int, pcount : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(DATAGRAM_HEADER_SIZE, b'\x00')
  put_u32_be(out, 0, sec)
  put_u32_be(out, 4, usec)
  put_u32_be(out, 8, pcount)
  Bytes::from_array(out)
}

/// Encode the 16-byte header used when udp_counters_64bit is negotiated:
/// the counter becomes an 8-byte big-endian word.
pub fn encode_datagram_header64(
  sec : Int,
  usec : Int,
  pcount : Int64,
) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(DATAGRAM_HEADER_SIZE_64, b'\x00')
  put_u32_be(out, 0, sec)
  put_u32_be(out, 4, usec)
  put_u64_be(out, 8, pcount)
  Bytes::from_array(out)
}

/// Decode a datagram header. Returns (sec, usec, pcount), or None when the
/// payload is shorter than the negotiated header size.
pub fn decode_datagram_header(
  b : Bytes,
  counters64 : Bool,
) -> (Int, Int, Int64)? {
  let need = if counters64 {
    DATAGRAM_HEADER_SIZE_64
  } else {
    DATAGRAM_HEADER_SIZE
  }
  if b.length() < need {
    return None
  }
  let sec = get_u32_be(b, 0)
  let usec = get_u32_be(b, 4)
  let pcount = if counters64 {
    get_u64_be(b, 8)
  } else {
    get_u32_be(b, 8).to_int64()
  }
  Some((sec, usec, pcount))
}
