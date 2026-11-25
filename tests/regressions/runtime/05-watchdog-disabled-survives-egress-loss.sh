#!/usr/bin/env bash
# Edge case:  EGRESS_FAIL_THRESHOLD=0 must fully disable the egress watchdog
# Root cause: Debugging sessions and custom proxy-mode setups rely on
#             EGRESS_FAIL_THRESHOLD=0 to prevent restart-looping when the
#             default egress check fails.
# Contract:   With EGRESS_FAIL_THRESHOLD=0 and an unreachable WARP_TRACE_URL,
#             the supervisor never logs egress failures and keeps the container
#             running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
RUN_ID="cfwarp-reg05-$$"
VOL="${RUN_ID}-data"
CNAME="${RUN_ID}"

cleanup() {
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_section "Regression: EGRESS_FAIL_THRESHOLD=0 disables egress watchdog"

docker volume create "$VOL" >/dev/null
docker run -d --name "$CNAME" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e EGRESS_FAIL_THRESHOLD=0 \
    -e EGRESS_GRACE_PERIOD=0 \
    -e EGRESS_CHECK_INTERVAL=2 \
    -e WARP_TRACE_URL="https://127.0.0.1:1/unreachable" \
    -v "${VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

sleep 18

c_state="$(docker inspect -f '{{.State.Status}}' "$CNAME")"
assert_eq "$c_state" "running" "Container stays running when EGRESS_FAIL_THRESHOLD=0 despite unreachable trace URL"

logs="$(docker logs "$CNAME" 2>&1 || true)"
if grep -qF "egress check failed" <<< "$logs"; then
    fail "Watchdog unexpectedly ran egress checks when EGRESS_FAIL_THRESHOLD=0" "$logs"
else
    pass "Zero egress watchdog failures logged when EGRESS_FAIL_THRESHOLD=0"
fi

finish_suite "regression-05-watchdog-disabled-survives-egress-loss"
