/// iperf3 EXCHANGE_RESULTS JSON payloads (src/iperf_api.c `send_results` /
/// `get_results`). The client sends its results first, then reads the
/// server's; the server does the reverse.

pub(all) struct StreamResult {
  /// iperf3 stream id (its socket fd on the sending side).
  id : Int
  /// Bytes sent (sender) or received (receiver) inside the measured window.
  bytes : Int64
  /// TCP retransmissions; -1 = not measured (e.g. non-Linux sender).
  retransmits : Int64
  /// UDP jitter in milliseconds (RFC 1889 estimator); 0 for TCP.
  jitter : Double
  /// UDP lost datagrams; -1 when unknown.
  errors : Int64
  /// UDP datagrams lost during the omitted warm-up window.
  omitted_errors : Int64
  /// UDP datagrams received (receiver) or sent (sender); -1 when unknown.
  packets : Int64
  /// UDP datagrams received during the omitted warm-up window.
  omitted_packets : Int64
  /// Interval start relative to test start, seconds.
  start_time : Double
  /// Interval end relative to test start, seconds.
  end_time : Double
}

pub(all) struct Results {
  cpu_util_total : Double
  cpu_util_user : Double
  cpu_util_system : Double
  /// Whether this side measured TCP retransmissions (iperf3 flag).
  sender_has_retransmits : Int64
  streams : Array[StreamResult]
}

/// Build a Results containing one stream.
pub fn Results::single(stream : StreamResult) -> Results {
  {
    cpu_util_total: 0.0,
    cpu_util_user: 0.0,
    cpu_util_system: 0.0,
    sender_has_retransmits: 0L,
    streams: [stream],
  }
}

/// Serialize into the EXCHANGE_RESULTS JSON object.
pub fn Results::to_json(self : Results) -> @json.Json {
  let streams = self
    .streams
    .iter()
    .map(fn(stream) { stream.to_json() })
    .collect()
  jobj([
    ("cpu_util_total", jnum(self.cpu_util_total)),
    ("cpu_util_user", jnum(self.cpu_util_user)),
    ("cpu_util_system", jnum(self.cpu_util_system)),
    ("sender_has_retransmits", jnum64(self.sender_has_retransmits)),
    ("streams", jarr(streams)),
  ])
}

/// Serialize one stream result.
pub fn StreamResult::to_json(self : StreamResult) -> @json.Json {
  jobj([
    ("id", jnum(self.id.to_double())),
    ("bytes", jnum64(self.bytes)),
    ("retransmits", jnum64(self.retransmits)),
    ("jitter", jnum(self.jitter)),
    ("errors", jnum64(self.errors)),
    ("omitted_errors", jnum64(self.omitted_errors)),
    ("packets", jnum64(self.packets)),
    ("omitted_packets", jnum64(self.omitted_packets)),
    ("start_time", jnum(self.start_time)),
    ("end_time", jnum(self.end_time)),
  ])
}

/// Fetch a field of a JSON object by (dynamic) key.
fn obj_get(j : @json.Json, key : String) -> @json.Json? {
  match j {
    @json.Json::Object(map) => map.get(key)
    _ => None
  }
}

fn get_num(j : @json.Json, key : String, fallback : Double) -> Double {
  match obj_get(j, key) {
    Some(@json.Json::Number(v, ..)) => v
    _ => fallback
  }
}

fn get_i64(j : @json.Json, key : String, fallback : Int64) -> Int64 {
  match obj_get(j, key) {
    Some(@json.Json::Number(v, ..)) => v.to_int64()
    _ => fallback
  }
}

/// Parse an EXCHANGE_RESULTS JSON object (as sent by a real iperf3 peer).
/// Missing fields fall back to neutral values.
pub fn Results::from_json(j : @json.Json) -> Results {
  let streams : Array[StreamResult] = []
  match obj_get(j, "streams") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        streams.push(StreamResult::from_json(item))
      }
    }
    _ => ()
  }
  {
    cpu_util_total: get_num(j, "cpu_util_total", 0.0),
    cpu_util_user: get_num(j, "cpu_util_user", 0.0),
    cpu_util_system: get_num(j, "cpu_util_system", 0.0),
    sender_has_retransmits: get_i64(j, "sender_has_retransmits", 0L),
    streams,
  }
}

fn StreamResult::from_json(j : @json.Json) -> StreamResult {
  {
    id: get_num(j, "id", 0.0).to_int(),
    bytes: get_i64(j, "bytes", 0L),
    retransmits: get_i64(j, "retransmits", -1L),
    jitter: get_num(j, "jitter", 0.0),
    errors: get_i64(j, "errors", -1L),
    omitted_errors: get_i64(j, "omitted_errors", 0L),
    packets: get_i64(j, "packets", -1L),
    omitted_packets: get_i64(j, "omitted_packets", 0L),
    start_time: get_num(j, "start_time", 0.0),
    end_time: get_num(j, "end_time", 0.0),
  }
}
