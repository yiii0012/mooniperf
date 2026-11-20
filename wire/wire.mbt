/// Control-channel wire I/O over a TCP socket: state bytes, JSON messages,
/// cookies and raw reads. All functions return `None`-style failures instead
/// of raising, so callers can unwind the protocol cleanly on disconnect.

/// Write a bare state byte.
pub async fn write_state(sock : @socket.Tcp, state : Int) -> Unit {
  let b : FixedArray[Byte] = FixedArray::make(1, @ctl.state_to_byte(state))
  sock.write(Bytes::from_array(b))
}

/// Read a bare state byte. None = connection closed.
pub async fn read_state(sock : @socket.Tcp) -> Int? {
  match read_n(sock, 1) {
    Some(b) => Some(@ctl.state_from_byte(b[0]))
    None => None
  }
}

/// Write a length-prefixed JSON message.
pub async fn write_json_msg(sock : @socket.Tcp, json : @json.Json) -> Unit {
  sock.write(@ctl.encode_json_message(json))
}

/// Read a length-prefixed JSON message. None = connection closed or
/// truncated/oversized payload.
pub async fn read_json_msg(sock : @socket.Tcp) -> @json.Json? {
  match read_n(sock, 4) {
    Some(sz) => {
      let n = @ctl.get_u32_be(sz, 0)
      if n > @ctl.MAX_PARAMS_JSON_LEN * 8 {
        // Sanity cap well above any legitimate message; iperf3 caps params
        // at 8 KiB, results can be larger with many streams.
        None
      } else if n == 0 {
        Some(@ctl.jobj([]))
      } else {
        match read_n(sock, n) {
          Some(body) =>
            try Some(@ctl.decode_json_message(body)) catch {
              _ => None
            }
          None => None
        }
      }
    }
    None => None
  }
}

/// Read exactly `n` bytes; None on EOF/truncation.
pub async fn read_n(sock : @socket.Tcp, n : Int) -> Bytes? {
  if n == 0 {
    return Some(b"")
  }
  let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut got = 0
  while got < n {
    let r = sock.read(buf, offset=got, max_len=n - got)
    if r <= 0 {
      return None
    }
    got += r
  }
  Some(Bytes::from_array(buf))
}

/// Read the 37-byte control cookie. None on EOF.
pub async fn read_cookie(sock : @socket.Tcp) -> Bytes? {
  read_n(sock, @ctl.COOKIE_SIZE)
}

/// Write the 37-byte control cookie.
pub async fn write_cookie(sock : @socket.Tcp, cookie : Bytes) -> Unit {
  sock.write(cookie)
}

/// Bytes equality helper for fixed-length comparisons.
pub fn same_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i += 1
  }
  true
}

/// Copy the first `len` bytes of a receive buffer into an immutable Bytes.
pub fn bytes_of(buf : FixedArray[Byte], len : Int) -> Bytes {
  let n = if len > buf.length() { buf.length() } else { len }
  let out : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut i = 0
  while i < n {
    out[i] = buf[i]
    i += 1
  }
  Bytes::from_array(out)
}
