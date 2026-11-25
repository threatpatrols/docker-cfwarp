#!/usr/bin/env bash
# Edge case:  `docker stop` during the setup phase (before gost starts)
# Root cause: Previously the TERM/INT trap was installed only after setup and
#             plain foreground `sleep` deferred signals, causing `docker stop`
#             during startup to hang 10s until SIGKILL (ExitCode=137).
# Contract:   Stopping a container mid-setup (WARP_SLEEP=20) exits cleanly with
#             ExitCode=0 in <= 4s.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
RUN_ID="cfwarp-reg03-$$"
VOL="${RUN_ID}-data"
CNAME="${RUN_ID}"

cleanup() {
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_section "Regression: clean docker stop during setup phase"

docker volume create "$VOL" >/dev/null
docker run -d --name "$CNAME" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e WARP_SLEEP=20 \
    -v "${VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

# Wait 2s so entrypoint is mid-setup inside interruptible_sleep "$WARP_SLEEP"
sleep 2

t0="$(date +%s)"
docker stop "$CNAME" >/dev/null
t1="$(date +%s)"
elapsed=$((t1 - t0))
rc="$(docker inspect -f '{{.State.ExitCode}}' "$CNAME")"

assert_eq "$rc" "0" "docker stop mid-setup exits cleanly with ExitCode=0 (not 137 SIGKILL)"
if [ "$elapsed" -le 4 ]; then
    pass "docker stop mid-setup finished quickly (${elapsed}s <= 4s)"
else
    fail "docker stop mid-setup took too long (${elapsed}s > 4s)"
fi

finish_suite "regression-03-stop-during-setup-clean-exit"
