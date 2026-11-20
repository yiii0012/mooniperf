/// Final summary (human text) and the iperf3-compatible `-J` JSON @report.

/// Human-readable final summary, iperf3 layout.
fn print_final(
  cfg : ClientConfig,
  st : CStats,
  server : @ctl.Results,
  t0 : Int64,
  end_t : Int64,
) -> Unit {
  let elapsed = (end_t - t0).to_double() / 1000.0
  let window = elapsed - cfg.omit.to_double()
  println("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -")
  if cfg.udp {
    println("[ ID] Interval           Transfer     Bitrate         Jitter    Lost/Total  Lost%")
    for id in st.bytes.keys() {
      let bytes = mget64(st.bytes, id, 0L)
      let pkts = mget64(st.packets, id, 0L)
      let bps = @stats.bits_per_second(bytes, window)
      let sb = StringBuilder()
      sb.write_string(@report.interval_prefix(id, cfg.omit.to_double(), elapsed))
      sb.write_string(@report.pad_right(@report.fmt_bytes(bytes), 13))
      sb.write_string(@report.fmt_bps(bps))
      sb.write_string("  0.000 ms  0/\{pkts} (0.00%)")
      sb.write_string("    sender")
      println(sb.to_string())
    }
    for s in server.streams {
      let window_s = s.end_time - s.start_time
      let bps = @stats.bits_per_second(s.bytes, window_s)
      let sb = StringBuilder()
      sb.write_string(@report.interval_prefix(s.id, s.start_time, s.end_time))
      sb.write_string(@report.pad_right(@report.fmt_bytes(s.bytes), 13))
      sb.write_string(@report.fmt_bps(bps))
      sb.write_string("  \{@report.fixed(s.jitter, 3)} ms")
      // iperf3 derives the final loss from sent - received.
      let sent_pkts = total_packets(st)
      let recv_pkts = s.packets
      let lost = if sent_pkts - recv_pkts < 0L {
        0L
      } else {
        sent_pkts - recv_pkts
      }
      let pct = if sent_pkts > 0L {
        lost.to_double() / sent_pkts.to_double() * 100.0
      } else {
        0.0
      }
      sb.write_string("  \{lost}/\{sent_pkts} (\{@report.fixed(pct, 2)}%)")
      sb.write_string("    receiver")
      println(sb.to_string())
    }
  } else {
    println("[ ID] Interval           Transfer     Bitrate         Retr")
    for id in st.bytes.keys() {
      let bytes = mget64(st.bytes, id, 0L)
      let bps = @stats.bits_per_second(bytes, window)
      let sb = StringBuilder()
      sb.write_string(@report.interval_prefix(id, cfg.omit.to_double(), elapsed))
      sb.write_string(@report.pad_right(@report.fmt_bytes(bytes), 13))
      sb.write_string(@report.fmt_bps(bps))
      sb.write_string(@report.pad_left("0", 8))
      sb.write_string("             sender")
      println(sb.to_string())
    }
    for s in server.streams {
      let window_s = s.end_time - s.start_time
      let bps = @stats.bits_per_second(s.bytes, window_s)
      let sb = StringBuilder()
      sb.write_string(@report.interval_prefix(s.id, s.start_time, s.end_time))
      sb.write_string(@report.pad_right(@report.fmt_bytes(s.bytes), 13))
      sb.write_string(@report.fmt_bps(bps))
      sb.write_string("                  receiver")
      println(sb.to_string())
    }
  }
  println("")
  println("iperf Done.")
  ()
}

fn jnum(v : Double) -> @json.Json { @ctl.jnum(v) }

fn jnum64(v : Int64) -> @json.Json { @ctl.jnum64(v) }

fn jstr(v : String) -> @json.Json { @ctl.jstr(v) }

fn jbool(v : Bool) -> @json.Json { @ctl.jbool(v) }

fn pair(k : String, v : @json.Json) -> (String, @json.Json) {
  (k, v)
}

fn obj(fields : Array[(String, @json.Json)]) -> @json.Json { @ctl.jobj(fields) }

/// Build a stream/sum entry with the TCP- or UDP-specific tail fields.
fn stream_entry(
  socket : Int,
  start : Double,
  end : Double,
  bytes : Int64,
  sender : Bool,
  udp : Bool,
  packets : Int64,
  jitter : Double,
  lost : Int64,
  retransmits : Int64,
) -> @json.Json {
  let bps = @stats.bits_per_second(bytes, end - start)
  let fields : Array[(String, @json.Json)] = [
    pair("socket", jnum(socket.to_double())),
    pair("start", jnum(start)),
    pair("end", jnum(end)),
    pair("seconds", jnum(end - start)),
    pair("bytes", jnum64(bytes)),
    pair("bits_per_second", jnum(bps)),
    pair("sender", jbool(sender)),
  ]
  if udp {
    let pct = if packets > 0L && lost >= 0L {
      lost.to_double() / packets.to_double() * 100.0
    } else {
      0.0
    }
    fields.push(pair("packets", jnum64(packets)))
    fields.push(pair("jitter_ms", jnum(jitter)))
    fields.push(pair("lost_packets", jnum64(lost)))
    fields.push(pair("lost_percent", jnum(pct)))
    fields.push(pair("out_of_order", jnum64(0L)))
  } else {
    fields.push(pair("retransmits", jnum64(retransmits)))
    fields.push(pair("max_snd_cwnd", jnum64(0L)))
    fields.push(pair("snd_wnd", jnum64(0L)))
    fields.push(pair("rtt", jnum64(0L)))
    fields.push(pair("rttvar", jnum64(0L)))
    fields.push(pair("pmtu", jnum64(0L)))
  }
  obj(fields)
}

/// Interval record entry (subset of stream_entry, sender-side only).
fn interval_entry(rec : IRecord, udp : Bool, sender : Bool) -> @json.Json {
  let bps = @stats.bits_per_second(rec.bytes, rec.end - rec.start)
  let fields : Array[(String, @json.Json)] = [
    pair("socket", jnum(rec.socket.to_double())),
    pair("start", jnum(rec.start)),
    pair("end", jnum(rec.end)),
    pair("seconds", jnum(rec.end - rec.start)),
    pair("bytes", jnum64(rec.bytes)),
    pair("bits_per_second", jnum(bps)),
    pair("omitted", jbool(rec.omitted)),
    pair("sender", jbool(sender)),
  ]
  if udp {
    fields.push(pair("packets", jnum64(rec.packets)))
    fields.push(pair("jitter_ms", jnum(0.0)))
    fields.push(pair("lost_packets", jnum64(0L)))
    fields.push(pair("lost_percent", jnum(0.0)))
    fields.push(pair("out_of_order", jnum64(0L)))
  } else {
    fields.push(pair("retransmits", jnum64(-1L)))
  }
  obj(fields)
}

/// Build the `-J` report, following iperf3's top-level structure:
/// start / intervals / end{streams, sum_sent, sum_received,
/// cpu_utilization_percent, congestion-control strings}.
fn build_json_report(
  cfg : ClientConfig,
  st : CStats,
  intervals : Array[IRecord],
  server : @ctl.Results,
  t0 : Int64,
  end_t : Int64,
) -> @json.Json {
  let elapsed = (end_t - t0).to_double() / 1000.0
  let window = elapsed - cfg.omit.to_double()
  let recs = intervals
    .iter()
    .map(fn(rec) { interval_entry(rec, cfg.udp, not(cfg.reverse)) })
    .collect()
  // end.streams: client-side entries first (marked by our role), then the
  // remote side from the EXCHANGE_RESULTS payload.
  let end_streams : Array[@json.Json] = []
  for id in st.bytes.keys() {
    end_streams.push(
      stream_entry(
        id,
        cfg.omit.to_double(),
        elapsed,
        mget64(st.bytes, id, 0L),
        not(cfg.reverse),
        cfg.udp,
        mget64(st.packets, id, 0L),
        mgetd(st.jitter, id, 0.0),
        0L,
        -1L,
      ),
    )
  }
  let mut recv_bytes : Int64 = 0L
  let mut recv_packets : Int64 = 0L
  let mut recv_jitter : Double = 0.0
  for s in server.streams {
    end_streams.push(
      stream_entry(
        s.id,
        s.start_time,
        s.end_time,
        s.bytes,
        cfg.reverse,
        cfg.udp,
        s.packets,
        s.jitter,
        s.errors,
        s.retransmits,
      ),
    )
    recv_bytes += s.bytes
    recv_packets += s.packets
    recv_jitter = s.jitter
  }
  // iperf3-style final loss: sent - received.
  let sent_packets = total_packets(st)
  let lost = if sent_packets - recv_packets < 0L {
    0L
  } else {
    sent_packets - recv_packets
  }
  let sent_bytes = total_bytes(st)
  let sent_bps = @stats.bits_per_second(sent_bytes, window)
  let recv_bps = @stats.bits_per_second(recv_bytes, window)
  let cpu = obj([
    pair("host_total", jnum(0.0)),
    pair("host_user", jnum(0.0)),
    pair("host_system", jnum(0.0)),
    pair("remote_total", jnum(0.0)),
    pair("remote_user", jnum(0.0)),
    pair("remote_system", jnum(0.0)),
  ])
  let end_obj = obj([
    pair("streams", @ctl.jarr(end_streams)),
    pair(
      "sum_sent",
      stream_entry(
        -1,
        cfg.omit.to_double(),
        elapsed,
        sent_bytes,
        not(cfg.reverse),
        cfg.udp,
        sent_packets,
        0.0,
        0L,
        -1L,
      ),
    ),
    pair(
      "sum_received",
      stream_entry(
        -1,
        cfg.omit.to_double(),
        elapsed,
        recv_bytes,
        cfg.reverse,
        cfg.udp,
        recv_packets,
        recv_jitter,
        lost,
        -1L,
      ),
    ),
    pair("cpu_utilization_percent", cpu),
    pair("sender_tcp_congestion_control", jstr("")),
    pair("receiver_tcp_congestion_control", jstr("")),
  ])
  let start_obj = obj([
    pair("version", jstr(VERSION)),
    pair("system_info", jstr("MoonBit native")),
    pair(
      "test_start",
      obj([
        pair("protocol", jstr(if cfg.udp { "UDP" } else { "TCP" })),
        pair("num_streams", jnum(cfg.parallel.to_double())),
        pair("blksize", jnum(effective_blksize(cfg).to_double())),
        pair("omit", jnum(cfg.omit.to_double())),
        pair("duration", jnum(cfg.time.to_double())),
        pair("bytes", jnum64(cfg.num_bytes)),
        pair("blockcount", jnum64(cfg.blockcount)),
        pair("send_window", jnum(cfg.window.to_double())),
        pair("parallel", jnum(cfg.parallel.to_double())),
        pair("reverse", jnum(if cfg.reverse { 1.0 } else { 0.0 })),
        pair("udp", jbool(cfg.udp)),
      ]),
    ),
  ])
  obj([
    pair("start", start_obj),
    pair("intervals", @ctl.jarr(recs)),
    pair("end", end_obj),
  ])
}
