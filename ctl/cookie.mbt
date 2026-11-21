///|
/// iperf3 control-connection cookie.
///
/// iperf3 sends a 37-byte cookie (`COOKIE_SIZE`) as the first bytes of the
/// control connection and of every data connection; the server compares them
/// to reject stale/foreign data connections (mismatch -> ACCESS_DENIED).
/// The canonical format is a 36-character ASCII identifier plus a NUL byte.
const COOKIE_CHARS : String = "abcdefghijklmnopqrstuvwxyz234567"

///|
/// Size of the cookie on the wire.
pub const COOKIE_SIZE : Int32 = 37

///|
/// Generate a fresh cookie: 36 random characters from the base32-like
/// charset followed by a NUL byte, 37 bytes in total.
pub fn new_cookie() -> Bytes {
  let rand = @random.Rand::Rand()
  let out : FixedArray[Byte] = FixedArray::make(COOKIE_SIZE, b'\x00')
  let chars = @utf8.encode(COOKIE_CHARS)
  let n = chars.length()
  let mut i = 0
  while i < 36 {
    out[i] = chars[rand.int(limit=n)]
    i += 1
  }
  out[36] = b'\x00'
  Bytes::from_array(out)
}
