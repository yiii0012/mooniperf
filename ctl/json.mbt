/// Small construction helpers for read-only Json values. The Json enum
/// itself cannot be constructed outside core, so every builder goes through
/// the official `Json::object/array/number/...` helpers.

pub fn jnum(v : Double) -> @json.Json {
  @json.Json::number(v)
}

pub fn jnum64(v : Int64) -> @json.Json {
  @json.Json::number(v.to_double())
}

pub fn jint(v : Int) -> @json.Json {
  @json.Json::number(v.to_double())
}

pub fn jbool(b : Bool) -> @json.Json {
  @json.Json::boolean(b)
}

pub fn jstr(s : String) -> @json.Json {
  @json.Json::string(s)
}

pub fn jarr(items : Array[@json.Json]) -> @json.Json {
  @json.Json::array(items)
}

/// Build a Json object from an ordered field list.
pub fn jobj(fields : Array[(String, @json.Json)]) -> @json.Json {
  let m : Map[String, @json.Json] = Map::new()
  for f in fields {
    m.set(f.0, f.1)
  }
  @json.Json::object(m)
}

/// Read a JSON boolean (True/False variants), None for other types.
pub fn jbool_of(j : @json.Json) -> Bool? {
  match j {
    @json.Json::True => Some(true)
    @json.Json::False => Some(false)
    _ => None
  }
}
