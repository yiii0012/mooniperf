/// Control-channel state bytes of the iperf3 protocol.
///
/// The iperf3 control connection multiplexes two kinds of messages:
/// a bare signed state byte, and (for some states) a JSON payload
/// framed as a 4-byte big-endian length prefix followed by UTF-8 text.
/// Values are taken from iperf3 `src/iperf_api.h`.

/// Test is starting (server -> client, bare byte).
pub const TEST_START : Int = 1
/// Data transfer phase is running (server -> client, bare byte).
pub const TEST_RUNNING : Int = 2
/// RESULT_REQUEST = 3, unused by iperf3.
/// Client finished sending data (client -> server, bare byte).
pub const TEST_END : Int = 4
/// Parameter exchange phase (server -> client, then client answers with JSON).
pub const PARAM_EXCHANGE : Int = 9
/// Client may open its data connections (server -> client, bare byte).
pub const CREATE_STREAMS : Int = 10
/// Server aborted the test (server -> client, bare byte).
pub const SERVER_TERMINATE : Int = 11
/// Client aborts the test (client -> server, bare byte).
pub const CLIENT_TERMINATE : Int = 12
/// Final result exchange (server -> client, then both sides send JSON results).
pub const EXCHANGE_RESULTS : Int = 13
/// Results exchange finished; client should display (server -> client, bare byte).
pub const DISPLAY_RESULTS : Int = 14
/// Local-only state in iperf3, defined for completeness.
pub const IPERF_START : Int = 15
/// Client -> server: test is complete, tear down (bare byte).
pub const IPERF_DONE : Int = 16
/// Server -> data connection: cookie mismatch (bare byte, negative).
pub const ACCESS_DENIED : Int = -1
/// Server -> client: failure, followed by two big-endian u32 (i_errno, errno).
pub const SERVER_ERROR : Int = -2

/// Encode a state value into the single wire byte.
/// iperf3 writes `sizeof(signed char)` = 1 byte, negative states map to 0xFF/0xFE.
pub fn state_to_byte(state : Int) -> Byte {
  (state & 0xFF).to_byte()
}

/// Encode a bare state message as a one-byte payload, ready to write.
pub fn encode_state_byte(state : Int) -> Bytes {
  Bytes::from_array(FixedArray::make(1, state_to_byte(state)))
}

/// Decode a single wire byte into the signed state value.
pub fn state_from_byte(b : Byte) -> Int {
  let v = b.to_int()
  if v >= 128 {
    v - 256
  } else {
    v
  }
}

/// Encode a SERVER_ERROR payload: two big-endian u32 words (i_errno, errno),
/// appended right after the SERVER_ERROR state byte.
pub fn encode_server_error(i_errno : Int, errno : Int) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(9, b'\x00')
  out[0] = state_to_byte(SERVER_ERROR)
  put_u32_be(out, 1, i_errno)
  put_u32_be(out, 5, errno)
  Bytes::from_array(out)
}

/// Decode a SERVER_ERROR frame: the full 9-byte payload consisting of the
/// state byte followed by two big-endian u32 words (i_errno, errno).
pub fn decode_server_error(payload : Bytes) -> (Int, Int) {
  let a = get_u32_be(payload, 1)
  let b = get_u32_be(payload, 5)
  (a, b)
}

///----- byte helpers shared by the framing codecs -----///

/// Store `v` as a 4-byte big-endian word at offset `off` of `buf`.
pub fn put_u32_be(buf : FixedArray[Byte], off : Int, v : Int) -> Unit {
  buf[off] = ((v >> 24) & 0xFF).to_byte()
  buf[off + 1] = ((v >> 16) & 0xFF).to_byte()
  buf[off + 2] = ((v >> 8) & 0xFF).to_byte()
  buf[off + 3] = (v & 0xFF).to_byte()
}

/// Store `v` as an 8-byte big-endian word at offset `off` of `buf`.
pub fn put_u64_be(buf : FixedArray[Byte], off : Int, v : Int64) -> Unit {
  let u = v.reinterpret_as_uint64()
  let mut i = 0
  while i < 8 {
    let shift = (7 - i) * 8
    buf[off + i] = ((u >> shift) & 0xFFUL).to_byte()
    i += 1
  }
}

/// Read a 4-byte big-endian word at offset `off` of `buf`.
pub fn get_u32_be(buf : Bytes, off : Int) -> Int {
  (buf[off].to_int() << 24) |
  (buf[off + 1].to_int() << 16) |
  (buf[off + 2].to_int() << 8) |
  buf[off + 3].to_int()
}

/// Read an 8-byte big-endian word at offset `off` of `buf`.
pub fn get_u64_be(buf : Bytes, off : Int) -> Int64 {
  let mut acc : UInt64 = 0UL
  let mut i = 0
  while i < 8 {
    acc = (acc << 8) | buf[off + i].to_int().to_uint64()
    i += 1
  }
  acc.reinterpret_as_int64()
}
