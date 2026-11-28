#!/usr/bin/env bash
# Cross-implementation interop matrix: mooniperf <-> real iperf3.
#
# Usage: interop.sh <mooniperf-binary> <iperf3-binary> [port]
#
# Each case starts one implementation in server mode, drives it with the
# other in client mode, and requires BOTH sides to finish cleanly (client
# exit 0; the server must stay alive for the next case). Mirrors the matrix
# documented in docs/protocol.md (iperf 3.1.3, 2026-11-21/22).
set -u

MI=$1
I3=$2
PORT=${3:-15601}

# Fail fast with a clear message if the binaries do not look runnable —
# e.g. when a build-artifact glob hands us a .core file instead of the CLI.
if [ ! -x "$MI" ]; then
  echo "mooniperf binary not executable: $MI" >&2
  exit 2
fi
if [ ! -x "$I3" ]; then
  echo "iperf3 binary not executable: $I3" >&2
  exit 2
fi

pass=0
fail=0

srv_pid=""
cleanup() {
  if [ -n "${srv_pid:-}" ]; then
    kill "$srv_pid" 2>/dev/null
    wait "$srv_pid" 2>/dev/null
    srv_pid=""
  fi
}
trap cleanup EXIT

# start_server <binary> [extra args...]
start_server() {
  cleanup
  "$@" -s -p "$PORT" >/dev/null 2>&1 &
  srv_pid=$!
  # Wait until the server actually ACCEPTS on the port (up to 5s) instead of
  # a blind sleep — a fresh kill+restart can lag under runner load, and a
  # client that connects too early taints the whole case.
  local ready=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$srv_pid" 2>/dev/null; then
      break
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null
      ready=1
      break
    fi
    sleep 0.25
  done
  if [ -z "$ready" ]; then
    echo "  (note: server never accepted on port $PORT: $*)"
  fi
}

# Validate JSON read on stdin. CI runners have python3; some Windows setups
# only expose `python`.
json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool >/dev/null 2>&1
  elif command -v python >/dev/null 2>&1; then
    python -I -m json.tool >/dev/null 2>&1
  else
    cat >/dev/null && return 0
  fi
}

# expect_zero <label> <command...>
expect_zero() {
  label=$1
  shift
  out=$("$@" 2>&1)
  code=$?
  if [ $code -eq 0 ]; then
    pass=$((pass + 1))
    echo "  ok  $label"
  else
    fail=$((fail + 1))
    echo "  FAIL $label (exit=$code)"
    echo "$out" | tail -5 | sed 's/^/      | /'
    if [ -n "${srv_pid:-}" ] && ! kill -0 "$srv_pid" 2>/dev/null; then
      echo "      | (server process has died)"
    fi
  fi
}

# --- mooniperf client against real iperf3 server ---
echo "== mooniperf -> iperf3 =="
start_server "$I3"
expect_zero "TCP 1 stream"        "$MI" -c 127.0.0.1 -p "$PORT" -t 2
expect_zero "TCP -P 2"            "$MI" -c 127.0.0.1 -p "$PORT" -t 2 -P 2
expect_zero "TCP -P 3"            "$MI" -c 127.0.0.1 -p "$PORT" -t 2 -P 3
expect_zero "UDP 2 Mbit/s"        "$MI" -c 127.0.0.1 -p "$PORT" -u -b 2M -t 2
expect_zero "TCP -J json report"  "$MI" -c 127.0.0.1 -p "$PORT" -t 2 -J
expect_zero "TCP -O 1 omit"       "$MI" -c 127.0.0.1 -p "$PORT" -t 2 -O 1
expect_zero "TCP -n 32M"          "$MI" -c 127.0.0.1 -p "$PORT" -n 32M
expect_zero "TCP -k blocks"       "$MI" -c 127.0.0.1 -p "$PORT" -k 10000
expect_zero "--get-server-output" "$MI" -c 127.0.0.1 -p "$PORT" -t 2 --get-server-output

# --- real iperf3 client against mooniperf server ---
echo "== iperf3 -> mooniperf =="
start_server "$MI"
expect_zero "TCP 1 stream"        "$I3" -c 127.0.0.1 -p "$PORT" -t 2
expect_zero "TCP -P 2"            "$I3" -c 127.0.0.1 -p "$PORT" -t 2 -P 2
expect_zero "TCP -P 3"            "$I3" -c 127.0.0.1 -p "$PORT" -t 2 -P 3
expect_zero "UDP 2 Mbit/s"        "$I3" -c 127.0.0.1 -p "$PORT" -u -b 2M -t 2
expect_zero "TCP -O 1 omit"       "$I3" -c 127.0.0.1 -p "$PORT" -t 2 -O 1
expect_zero "TCP -n 32M"          "$I3" -c 127.0.0.1 -p "$PORT" -n 32M
expect_zero "--get-server-output" "$I3" -c 127.0.0.1 -p "$PORT" -t 2 --get-server-output

# --- -J report must be valid JSON ---
echo "== -J report validity =="
cleanup
"$I3" -s -p "$PORT" >/dev/null 2>&1 &
srv_pid=$!
sleep 1
if "$MI" -c 127.0.0.1 -p "$PORT" -t 2 -J 2>/dev/null | json_ok; then
  pass=$((pass + 1))
  echo "  ok  mooniperf -J parses as JSON"
else
  fail=$((fail + 1))
  echo "  FAIL mooniperf -J parses as JSON"
fi
if "$MI" -c 127.0.0.1 -p "$PORT" -t 2 2>/dev/null >/dev/null && "$I3" -c 127.0.0.1 -p "$PORT" -t 2 -J 2>/dev/null | json_ok; then
  pass=$((pass + 1))
  echo "  ok  iperf3 -J parses as JSON (driving mooniperf)"
else
  fail=$((fail + 1))
  echo "  FAIL iperf3 -J parses as JSON (driving mooniperf)"
fi

# --- CLI misuse must be refused with non-zero exit codes (iperf3 parity) ---
echo "== CLI misuse =="
expect_zero "refuses -t with -n"  sh -c "! '$MI' -c 127.0.0.1 -p 1 -t 2 -n 1000000"
expect_zero "refuses -t with -k"  sh -c "! '$MI' -c 127.0.0.1 -p 1 -t 2 -k 10"
expect_zero "refuses -n with -k"  sh -c "! '$MI' -c 127.0.0.1 -p 1 -n 1000 -k 10"
expect_zero "refuses -b garbage"  sh -c "! '$MI' -c 127.0.0.1 -p 1 -b abc"

cleanup
echo
echo "interop: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
