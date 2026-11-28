/// iperf3 wire error codes (i_errno) and their human-readable texts.
///
/// The SERVER_ERROR state is followed by two big-endian u32 words; the
/// first is an i_errno from iperf3's enum. Values and message texts below
/// are reproduced from iperf3 3.1.3 (src/iperf_api.h enum i_errno and
/// src/iperf_error.c iperf_strerror; BSD-3-Clause, ESnet) so that errors
/// reported by any iperf3-compatible peer render with the same wording
/// iperf3 itself would print. Messages whose iperf3 text embeds runtime
/// constants (%d/%g of MAX_* limits) show the documented constant instead.

///|
/// Human-readable text for an i_errno value, or None for unknown codes.
pub fn i_errno_to_text(code : Int32) -> String? {
  match code {
    0 => Some("no error")
    1 => Some("cannot be both server and client")
    2 => Some("must either be a client (-c) or server (-s)")
    3 => Some("some option you are trying to set is server only")
    4 => Some("some option you are trying to set is client only")
    5 => Some("test duration too long (maximum = 86400 seconds)")
    6 => Some("number of parallel streams too large (maximum = 128)")
    7 => Some("block size too large (maximum = 131072 bytes)")
    8 => Some("socket buffer size too large (maximum = (details) bytes)")
    9 => Some("invalid report interval (min = 0.5, max = 3600 seconds)")
    10 => Some("TCP MSS too large (maximum = 9216 bytes)")
    11 => Some("this OS does not support sendfile")
    12 => Some("bogus value for --omit")
    13 => Some("an option you are trying to set is not implemented yet")
    14 => Some("unable to open -F file")
    15 => Some("invalid burst count (maximum = (details))")
    16 => Some("only one test end condition (-t, -n, -k) may be specified")
    17 => Some("unable to open log file")
    18 => Some("no SCTP support available")
    19 => Some("--bind must be specified to use --cport")
    20 => Some("block size too large (maximum = 131072 bytes)")
    21 => Some("bad TOS value (must be between 0 and 255 inclusive)")
    100 => Some("unable to create a new test")
    101 => Some("test initialization failed")
    102 => Some("unable to start listener for connections")
    103 => Some("unable to connect to server")
    104 => Some("unable to accept connection from client")
    105 => Some("unable to send cookie to server")
    106 => Some("unable to receive cookie at server")
    107 => Some("unable to write to the control socket")
    108 => Some("unable to read from the control socket")
    109 => Some("control socket has closed unexpectedly")
    110 => Some("received an unknown control message")
    111 => Some("unable to send control message")
    112 => Some("unable to receive control message")
    113 => Some("unable to send parameters to server")
    114 => Some("unable to receive parameters from client")
    115 => Some("unable to package results")
    116 => Some("unable to send results")
    117 => Some("unable to receive results")
    118 => Some("select failed")
    119 => Some("the client has terminated")
    120 => Some("the server has terminated")
    121 => Some("the server is busy running a test. try again later")
    122 => Some("unable to set TCP/SCTP NODELAY")
    123 => Some("unable to set TCP/SCTP MSS")
    124 => Some("unable to set socket buffer size")
    125 => Some("unable to set IP TOS")
    126 => Some("unable to set IPv6 traffic class")
    127 => Some("unable to set IPv6 flow label")
    128 => Some("unable to reuse address on socket")
    129 => Some("unable to set socket to non-blocking")
    130 => Some("unable to set socket window size")
    131 => Some("protocol does not exist")
    132 => Some("unable to set CPU affinity")
    133 => Some("unable to become a daemon")
    134 => Some("unable to set TCP_CONGESTION")
    135 => Some("unable to write PID file")
    136 => Some("Unable to set/reset IPV6_V6ONLY")
    137 => Some("unable to set SCTP_DISABLE_FRAGMENTS")
    200 => Some("unable to create a new stream")
    201 => Some("unable to initialize stream")
    202 => Some("unable to start stream listener")
    203 => Some("unable to connect stream")
    204 => Some("unable to accept stream connection")
    205 => Some("unable to write to stream socket")
    206 => Some("unable to read from stream socket")
    207 => Some("stream socket has closed unexpectedly")
    208 => Some("stream has an invalid id")
    300 => Some("unable to create new timer")
    301 => Some("unable to update timer")
    _ => None
  }
}
