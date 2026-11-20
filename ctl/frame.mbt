/// Control-connection JSON framing, mirroring iperf3's `JSON_write`/`JSON_read`:
/// every JSON message is a 4-byte **big-endian** length prefix followed by the
/// UTF-8 encoded JSON text (no trailing newline).

/// Encode a JSON control message: `[u32 BE length][utf8 json text]`.
pub fn encode_json_message(json : @json.Json) -> Bytes {
  encode_json_text(json.stringify())
}

/// Same as `encode_json_message` but for pre-rendered JSON text.
pub fn encode_json_text(text : String) -> Bytes {
  let body = @utf8.encode(text)
  let len = body.length()
  let out : FixedArray[Byte] = FixedArray::make(len + 4, b'\x00')
  put_u32_be(out, 0, len)
  let mut i = 0
  while i < len {
    out[i + 4] = body[i]
    i += 1
  }
  Bytes::from_array(out)
}

/// Decode a length-prefixed JSON message body into a Json value.
/// `payload` must contain exactly the JSON text (without the 4-byte prefix).
pub fn decode_json_message(payload : Bytes) -> @json.Json raise {
  @json.parse(bytes_to_string(payload))
}

/// Decode UTF-8 bytes into a String.
pub fn bytes_to_string(payload : Bytes) -> String raise {
  @utf8.decode(payload)
}

/// Maximum params JSON length iperf3 accepts (MAX_PARAMS_JSON_LEN = 8 KiB).
pub const MAX_PARAMS_JSON_LEN : Int = 8192

/// Non-raising variant of `decode_json_message` for tests and tolerant paths.
pub fn decode_json_message_opt(payload : Bytes) -> @json.Json? {
  try Some(decode_json_message(payload)) catch {
    _ => None
  }
}