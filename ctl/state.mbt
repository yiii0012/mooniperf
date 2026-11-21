/// Control-channel state bytes of the iperf3 protocol.
///
/// The iperf3 control connection multiplexes two kinds of messages:
/// a bare signed state byte, and (for some states) a JSON payload
/// framed as a 4-byte big-endian length prefix followed by UTF-8 text.
/// Values are taken from iperf3 `src/iperf_api.h`.

///|
/// Test is starting (server -> client, bare byte).
pub const TEST_START : Int32 = 1

///|
/// Data transfer phase is running (server -> client, bare byte).
pub const TEST_RUNNING : Int32 = 2

///|
/// RESULT_REQUEST = 3, unused by iperf3.
/// Client finished sending data (client -> server, bare byte).
pub const TEST_END : Int32 = 4

///|
/// Parameter exchange phase (server -> client, then client answers with JSON).
pub const PARAM_EXCHANGE : Int32 = 9

///|
/// Client may open its data connections (server -> client, bare byte).
pub const CREATE_STREAMS : Int32 = 10

///|
/// Server aborted the test (server -> client, bare byte).
pub const SERVER_TERMINATE : Int32 = 11

///|
/// Client aborts the test (client -> server, bare byte).
pub const CLIENT_TERMINATE : Int32 = 12

///|
/// Final result exchange (server -> client, then both sides send JSON results).
pub const EXCHANGE_RESULTS : Int32 = 13

///|
/// Results exchange finished; client should display (server -> client, bare byte).
pub const DISPLAY_RESULTS : Int32 = 14

///|
/// Local-only state in iperf3, defined for completeness.
pub const IPERF_START : Int32 = 15

///|
/// Client -> server: test is complete, tear down (bare byte).
pub const IPERF_DONE : Int32 = 16

///|
/// Server -> data connection: cookie mismatch (bare byte, negative).
pub const ACCESS_DENIED : Int32 = -1

///|
/// Server -> client: failure, followed by two big-endian u32 (i_errno, errno).
pub const SERVER_ERROR : Int32 = -2

///|
/// Encode a state value into the single wire byte.
/// iperf3 writes `sizeof(signed char)` = 1 byte, negative states map to 0xFF/0xFE.
pub fn state_to_byte(state : Int32) -> Byte {
  (state & 0xFF).to_byte()
}

///|
/// Encode a bare state message as a one-byte payload, ready to write.
pub fn encode_state_byte(state : Int32) -> Bytes {
  Bytes::from_array(FixedArray::make(1, state_to_byte(state)))
}

///|
/// Decode a single wire byte into the signed state value.
pub fn state_from_byte(b : Byte) -> Int32 {
  let v = b.to_int()
  if v >= 128 {
    v - 256
  } else {
    v
  }
}

///|
/// iperf3 stream id for the k-th data connection (1-based ordinal).
///
/// `iperf_add_stream` (src/iperf_api.c) gives the FIRST stream id 1 and every
/// later stream `2 + <number of existing streams>` — a quirk of its list walk
/// starting the counter at 2 — so the sequence is 1, 3, 4, 5, ... Both peers
/// validate the ids in EXCHANGE_RESULTS against this exact sequence, so
/// mooniperf must reproduce it (a plain 1..N numbering fails with
/// "stream has an invalid id" as soon as -P > 1).
pub fn stream_id(ordinal : Int32) -> Int32 {
  if ordinal <= 1 {
    1
  } else {
    ordinal + 1
  }
}

///|
/// Encode a SERVER_ERROR payload: two big-endian u32 words (i_errno, errno),
/// appended right after the SERVER_ERROR state byte.
pub fn encode_server_error(i_errno : Int32, errno : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(9, b'\x00')
  out[0] = state_to_byte(SERVER_ERROR)
  put_u32_be(out, 1, i_errno)
  put_u32_be(out, 5, errno)
  Bytes::from_array(out)
}

///|
/// Decode a SERVER_ERROR frame: the full 9-byte payload consisting of the
/// state byte followed by two big-endian u32 words (i_errno, errno).
pub fn decode_server_error(payload : Bytes) -> (Int32, Int32) {
  let a = get_u32_be(payload, 1)
  let b = get_u32_be(payload, 5)
  (a, b)
}

///|
/// Decode a SERVER_ERROR *body*: the 8 bytes that follow the state byte on
/// the wire (two big-endian u32 words: i_errno, errno). Readers that already
/// consumed the state byte — like the client's control loop — use this
/// variant instead of re-wrapping a short payload in `decode_server_error`.
pub fn decode_server_error_body(payload : Bytes) -> (Int32, Int32) {
  let a = get_u32_be(payload, 0)
  let b = get_u32_be(payload, 4)
  (a, b)
}

///----- byte helpers shared by the framing codecs -----///

///|
/// Store `v` as a 4-byte big-endian word at offset `off` of `buf`.
pub fn put_u32_be(buf : FixedArray[Byte], off : Int32, v : Int32) -> Unit {
  buf[off] = ((v >> 24) & 0xFF).to_byte()
  buf[off + 1] = ((v >> 16) & 0xFF).to_byte()
  buf[off + 2] = ((v >> 8) & 0xFF).to_byte()
  buf[off + 3] = (v & 0xFF).to_byte()
}

///|
/// Store `v` as an 8-byte big-endian word at offset `off` of `buf`.
pub fn put_u64_be(buf : FixedArray[Byte], off : Int32, v : Int64) -> Unit {
  let u = v.reinterpret_as_uint64()
  let mut i = 0
  while i < 8 {
    let shift = (7 - i) * 8
    buf[off + i] = ((u >> shift) & 0xFFUL).to_byte()
    i += 1
  }
}

///|
/// Read a 4-byte big-endian word at offset `off` of `buf`.
pub fn get_u32_be(buf : Bytes, off : Int32) -> Int32 {
  (buf[off].to_int() << 24) |
  (buf[off + 1].to_int() << 16) |
  (buf[off + 2].to_int() << 8) |
  buf[off + 3].to_int()
}

///|
/// Read an 8-byte big-endian word at offset `off` of `buf`.
pub fn get_u64_be(buf : Bytes, off : Int32) -> Int64 {
  let mut acc : UInt64 = 0UL
  let mut i = 0
  while i < 8 {
    acc = (acc << 8) | buf[off + i].to_int().to_uint64()
    i += 1
  }
  acc.reinterpret_as_int64()
}
