#!/usr/bin/env bash
# Interleaved A/B of two flare_mc binaries on the plaintext keep-alive
# workload.
#
# Interleaved rather than back-to-back because this box is shared: a
# co-tenant job moves the achievable rate by more than the effect we
# are trying to detect. Alternating A,B,A,B,... puts both binaries
# under the same drifting ambient load, so the paired difference stays
# meaningful even when the absolute numbers do not.
set -uo pipefail

A_BIN="${A_BIN:?set A_BIN}"
B_BIN="${B_BIN:?set B_BIN}"
REPS="${REPS:-4}"
RATE="${RATE:-150000}"
DUR="${DUR:-20}"
PORT="${PORT:-8080}"
WRK2="${WRK2:-build/wrk2/wrk2}"

run_one() {
  local bin="$1"
  FLARE_BENCH_PORT="$PORT" FLARE_BENCH_WORKERS=4 "$bin" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:${PORT}/plaintext" >/dev/null 2>&1 && break
    sleep 0.2
  done
  local out
  out=$("$WRK2" -t8 -c256 -d${DUR}s -R${RATE} --latency \
        "http://127.0.0.1:${PORT}/plaintext" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 1
  local rps p99
  rps=$(awk '/Requests\/sec/{print $2}' <<<"$out")
  p99=$(awk '/ 99\.000%/{print $2}' <<<"$out")
  echo "${rps:-0} ${p99:-NA}"
}

echo "rep,side,req_per_s,p99"
for i in $(seq 1 "$REPS"); do
  read -r a_rps a_p99 <<<"$(run_one "$A_BIN")"
  echo "$i,A,$a_rps,$a_p99"
  read -r b_rps b_p99 <<<"$(run_one "$B_BIN")"
  echo "$i,B,$b_rps,$b_p99"
done
