#!/bin/bash
set -euo pipefail
PORT="${FLARE_BENCH_PORT:-8080}"
# FLARE_BENCH_TLS=1 makes the server terminate TLS, so probe https
# and skip verification (the bench certs are self-signed by design).
if [ "${FLARE_BENCH_TLS:-0}" = "1" ]; then
    URL="https://127.0.0.1:$PORT/plaintext"
    CURL_TLS_FLAG="-k"
else
    URL="http://127.0.0.1:$PORT/plaintext"
    CURL_TLS_FLAG=""
fi
# flare_mc compiles on first run (Mojo JIT) AND spawns N pthreads +
# binds N SO_REUSEPORT listeners, which adds a couple of hundred ms.
# 30s is plenty for a cold start.
for i in $(seq 1 60); do
    if curl --silent --fail $CURL_TLS_FLAG --max-time 1 "$URL" > /dev/null; then
        exit 0
    fi
    sleep 0.5
done
echo "check.sh: server did not answer after 30s at $URL"
exit 1
