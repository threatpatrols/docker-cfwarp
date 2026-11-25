#!/usr/bin/env bash
# Edge case:  Deliberate `warp-cli disconnect` must be preserved across restarts
#             and must not crash-loop when EGRESS_FAIL_THRESHOLD=0
# Root cause: Unconditionally calling `warp-cli connect` on every boot would
#             override operator intent during debugging; conversely, forgetting
#             to respect EGRESS_FAIL_THRESHOLD=0 would restart-loop the container.
# Contract:   After `warp-cli disconnect` + `docker restart` with
#             EGRESS_FAIL_THRESHOLD=0, WARP remains Disconnected and the
#             container stays running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
RUN_ID="cfwarp-reg01-$$"
VOL="${RUN_ID}-data"
CNAME="${RUN_ID}"

cleanup() {
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_section "Regression: deliberate disconnect preserved across restart"

docker volume create "$VOL" >/dev/null
docker run -d --name "$CNAME" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e EGRESS_FAIL_THRESHOLD=0 \
    -v "${VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

healthy=0
for _ in $(seq 1 30); do
    st="$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$CNAME")"
    if [ "$st" = "running healthy" ]; then
        healthy=1
        break
    fi
    sleep 2
done
assert_eq "$healthy" "1" "Initial boot reached healthy"

assert_cmd_ok "Deliberate warp-cli disconnect succeeds" \
    docker exec "$CNAME" warp-cli --accept-tos disconnect

docker restart "$CNAME" >/dev/null
sleep 10

status_after="$(docker exec "$CNAME" warp-cli --accept-tos status 2>&1 || true)"
assert_contains "$status_after" "Disconnected" "WARP remains Disconnected after restart"
assert_cmd_fail "connected-to-warp.sh reports unhealthy while disconnected" \
    docker exec "$CNAME" bash /healthcheck/connected-to-warp.sh

c_state="$(docker inspect -f '{{.State.Status}}' "$CNAME")"
assert_eq "$c_state" "running" "Container stays running with EGRESS_FAIL_THRESHOLD=0"

finish_suite "regression-01-deliberate-disconnect-preserved"
