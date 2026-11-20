/// RFC 1889 (section A.8) inter-arrival jitter estimator plus UDP
/// loss/out-of-order accounting — a faithful port of iperf3's receiver
/// logic in src/iperf_udp.c.

/// Accumulated receiver-side statistics for one UDP stream.
pub(all) struct UdpReceiver {
  /// Highest datagram sequence number seen so far.
  mut packet_count : Int64
  /// Datagrams lost inside the measured window (iperf3 cnt_error).
  mut cnt_error : Int64
  /// Datagrams lost during the omitted warm-up window.
  mut omitted_cnt_error : Int64
  /// Out-of-order / retransmitted datagrams observed.
  mut out_of_order : Int64
  /// RFC 1889 jitter estimate in seconds (iperf3 stores seconds and
  /// converts to milliseconds only when reporting).
  mut jitter : Double
  /// Previous transit time in seconds.
  mut prev_transit : Double
  /// Whether any datagram has been processed yet.
  mut first_packet : Bool
  /// Whether accounting is currently inside the omitted warm-up window.
  mut omitting : Bool
  /// Total bytes received (whole datagrams, header included, matching
  /// iperf3's bytes_received accounting).
  mut bytes_received : Int64
  /// Number of datagrams received.
  mut datagrams_received : Int64
}

pub fn UdpReceiver::new() -> UdpReceiver {
  {
    packet_count: 0L,
    cnt_error: 0L,
    omitted_cnt_error: 0L,
    out_of_order: 0L,
    jitter: 0.0,
    prev_transit: 0.0,
    first_packet: true,
    omitting: false,
    bytes_received: 0L,
    datagrams_received: 0L,
  }
}

/// Feed one datagram into the estimator.
///
/// - `pcount` is the sequence number from the datagram header.
/// - `transit` is the arrival time minus the sender timestamp embedded in
///   the header, in seconds. Absolute clock offsets cancel out because only
///   differences are used, so sender and receiver need no clock sync — this
///   matches iperf3, whose timestamps are wall-clock but whose jitter math
///   is purely differential.
/// - `size` is the whole datagram size in bytes.
pub fn UdpReceiver::on_datagram(
  self : UdpReceiver,
  pcount : Int64,
  transit : Double,
  size : Int,
) -> Unit {
  self.bytes_received += size.to_int64()
  self.datagrams_received += 1L
  // Jitter: smoothed absolute delta of successive transit times (RFC 1889).
  if self.first_packet {
    self.first_packet = false
    self.prev_transit = transit
  } else {
    let d = if transit - self.prev_transit < 0.0 {
      self.prev_transit - transit
    } else {
      transit - self.prev_transit
    }
    self.jitter += (d - self.jitter) / 16.0
    self.prev_transit = transit
  }
  // Sequence accounting: gaps are losses, backwards sequences are
  // reordering and credit one previously charged loss back, like iperf3.
  if self.datagrams_received == 1L && pcount <= self.packet_count {
    // First datagram merely initializes the sequence window.
    self.packet_count = pcount
    return
  }
  if pcount > self.packet_count + 1L {
    let gap = (pcount - 1L) - self.packet_count
    if self.omitting {
      self.omitted_cnt_error += gap
    } else {
      self.cnt_error += gap
    }
    self.packet_count = pcount
  } else if pcount <= self.packet_count {
    self.out_of_order += 1L
    if self.omitting {
      if self.omitted_cnt_error > 0L {
        self.omitted_cnt_error -= 1L
      }
    } else if self.cnt_error > 0L {
      self.cnt_error -= 1L
    }
  } else {
    self.packet_count = pcount
  }
}

/// Move the accounting into/out of the omitted warm-up window.
pub fn UdpReceiver::set_omitting(self : UdpReceiver, omitting : Bool) -> Unit {
  self.omitting = omitting
}

/// Jitter in milliseconds (iperf3 reports jitter * 1000).
pub fn UdpReceiver::jitter_ms(self : UdpReceiver) -> Double {
  self.jitter * 1000.0
}

/// Average lost datagrams over the received window, as the receiver itself
/// estimates it. The final iperf3-style summary instead derives loss from
/// sender_sent - receiver_received; both are kept apart on purpose.
pub fn UdpReceiver::loss_percent(self : UdpReceiver) -> Double {
  if self.packet_count <= 0L {
    return 0.0
  }
  (self.cnt_error.to_double() / self.packet_count.to_double()) * 100.0
}
