#!/usr/bin/env bash
# Edge case:  Black-holed WARP tunnel hangs curl indefinitely
# Root cause: Without --max-time, curl in connected-to-warp.sh can hang past
#             Docker's 5s HEALTHCHECK timeout and stall the supervisor loop
#             beyond docker stop's 10s grace period (fixed in 9ac198f).
# Contract:   connected-to-warp.sh must fail non-zero within <= 6s against a
#             TCP peer that accepts connections and never responds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

log_section "Regression: black-holed trace endpoint times out cleanly"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available for local TCP blackhole listener"
    finish_suite "regression-01-blackhole-curl-timeout"
fi

TMP_DIR="$(mktemp -d)"
PORT_FILE="${TMP_DIR}/port"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

python3 - "$PORT_FILE" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
conns = []
deadline = time.time() + 15
s.settimeout(1.0)
while time.time() < deadline:
    try:
        c, _ = s.accept()
        conns.append(c)  # accept and deliberately never reply
    except socket.timeout:
        pass
PY
SERVER_PID=$!

for _ in $(seq 1 30); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done

if [ ! -s "$PORT_FILE" ]; then
    fail "Failed to start local blackhole TCP listener"
    finish_suite "regression-01-blackhole-curl-timeout"
fi

port="$(cat "$PORT_FILE")"
t0="$(date +%s)"
rc=0
WARP_TRACE_URL="http://127.0.0.1:${port}/cdn-cgi/trace" \
    bash "${REPO_ROOT}/healthcheck/connected-to-warp.sh" >/dev/null 2>&1 || rc=$?
t1="$(date +%s)"
elapsed=$((t1 - t0))

if [ "$rc" -ne 0 ]; then
    pass "connected-to-warp.sh exited non-zero on blackhole (rc=${rc})"
else
    fail "connected-to-warp.sh unexpectedly succeeded on blackhole"
fi

if [ "$elapsed" -ge 3 ] && [ "$elapsed" -le 6 ]; then
    pass "connected-to-warp.sh bounded blackhole request to ${elapsed}s (target ~4s)"
else
    fail "Expected timeout around 4s (3..6s), got ${elapsed}s"
fi

finish_suite "regression-01-blackhole-curl-timeout"
