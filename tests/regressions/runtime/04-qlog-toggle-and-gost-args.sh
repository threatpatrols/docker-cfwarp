#!/usr/bin/env bash
# Edge case:  Custom GOST_ARGS, DEBUG_ENABLE_QLOG, and malformed numeric env vars
# Root cause: `set -e` in entrypoint.sh can crash on non-numeric values in
#             arithmetic expressions, and custom GOST_ARGS must parse cleanly
#             without pathname glob expansion.
# Contract:   Invalid numeric env vars fall back to safe defaults without
#             crashing startup, DEBUG_ENABLE_QLOG=1 succeeds, and custom
#             GOST_ARGS="-L :1081" serves WARP SOCKS5 on port 1081 (not 1080).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
RUN_ID="cfwarp-reg04-$$"
VOL="${RUN_ID}-data"
CNAME="${RUN_ID}"

cleanup() {
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_section "Regression: custom GOST_ARGS, DEBUG_ENABLE_QLOG, and invalid numeric env fallbacks"

docker volume create "$VOL" >/dev/null
docker run -d --name "$CNAME" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e GOST_ARGS="-L :1081" \
    -e DEBUG_ENABLE_QLOG=1 \
    -e WARP_SLEEP="notanumber" \
    -e EGRESS_FAIL_THRESHOLD="bogus" \
    -e EGRESS_CHECK_INTERVAL="0" \
    -e EGRESS_GRACE_PERIOD="invalid" \
    -v "${VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

healthy=0
for _ in $(seq 1 30); do
    st="$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$CNAME")"
    if [ "$st" = "running healthy" ]; then
        healthy=1
        break
    fi
    if [[ "$st" == exited* ]]; then
        break
    fi
    sleep 2
done
assert_eq "$healthy" "1" "Container reached healthy despite malformed numeric env vars + DEBUG_ENABLE_QLOG=1"

trace_1081="$(docker exec "$CNAME" curl -fsS --max-time 6 --socks5-hostname 127.0.0.1:1081 https://cloudflare.com/cdn-cgi/trace)"
assert_matches "$trace_1081" '^warp=(on|plus)$' "Custom GOST_ARGS=-L :1081 proxies WARP traffic on port 1081"

assert_cmd_fail "Default port 1080 is not listening when GOST_ARGS overrides port" \
    docker exec "$CNAME" curl -fsS --max-time 2 --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace

finish_suite "regression-04-qlog-toggle-and-gost-args"
