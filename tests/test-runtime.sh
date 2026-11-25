#!/usr/bin/env bash
# Live container integration tests for docker-cfwarp.
#
# Requires Docker with NET_ADMIN + tun cgroup rule support and outbound internet
# access to Cloudflare WARP. Uses throwaway containers and volumes and removes
# them on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "$REPO_ROOT"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"
BUILT_BY_SCRIPT=0

RUN_ID="cfwarp-test-$$"
DATA_VOL="${RUN_ID}-data"
C_MAIN="${RUN_ID}-main"
C_WD="${RUN_ID}-watchdog"

cleanup() {
    docker rm -f "$C_MAIN" "$C_WD" >/dev/null 2>&1 || true
    docker volume rm -f "$DATA_VOL" >/dev/null 2>&1 || true
    if [ "$BUILT_BY_SCRIPT" -eq 1 ] && [ "$KEEP_IMAGE" != "1" ]; then
        docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI not found in PATH"
    finish_suite "runtime"
fi

if [ "$SKIP_BUILD" != "1" ]; then
    log_section "Building ${IMAGE_TAG} for runtime tests"
    if docker build -t "$IMAGE_TAG" . >/dev/null; then
        BUILT_BY_SCRIPT=1
        pass "Built ${IMAGE_TAG}"
    else
        fail "Failed to build ${IMAGE_TAG}"
        finish_suite "runtime"
    fi
elif ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    fail "SKIP_BUILD=1 set, but image ${IMAGE_TAG} does not exist"
    finish_suite "runtime"
fi

wait_for_healthy() {
    local cname="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    local st=""
    while [ "$elapsed" -lt "$max_wait" ]; do
        st="$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$cname" 2>/dev/null || echo 'missing')"
        if [ "$st" = "running healthy" ]; then
            return 0
        fi
        if [[ "$st" == exited* ]]; then
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

wait_for_exit() {
    local cname="$1"
    local max_wait="${2:-30}"
    local elapsed=0
    local st=""
    while [ "$elapsed" -lt "$max_wait" ]; do
        st="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo 'missing')"
        if [ "$st" = "exited" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

docker volume create "$DATA_VOL" >/dev/null

# ---------------------------------------------------------------------------
# 1. Cold boot with WARP_ENABLE_NAT=1, healthcheck, SOCKS5, nft, host-conn
# ---------------------------------------------------------------------------
log_section "Cold boot, NAT mode, SOCKS5 egress, and healthcheck"

docker run -d --name "$C_MAIN" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv6.conf.all.accept_ra=2 \
    -e WARP_ENABLE_NAT=1 \
    -e EGRESS_GRACE_PERIOD=15 \
    -e EGRESS_CHECK_INTERVAL=5 \
    -v "${DATA_VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

if wait_for_healthy "$C_MAIN" 60; then
    pass "Container reached healthy on cold boot with WARP_ENABLE_NAT=1"
else
    fail "Container did not reach healthy within 60s" "$(docker logs --tail 20 "$C_MAIN" 2>&1)"
    finish_suite "runtime"
fi

assert_cmd_ok "warp-svc IPC socket present at /run/cloudflare-warp/warp_service" \
    docker exec "$C_MAIN" test -S /run/cloudflare-warp/warp_service

# shellcheck disable=SC2016
assert_cmd_ok "/proc/<pid>/comm matches 'warp-svc'" \
    docker exec "$C_MAIN" sh -c 'for p in /proc/[0-9]*/comm; do [ "$(cat "$p" 2>/dev/null)" = "warp-svc" ] && exit 0; done; exit 1'

nft_ip4="$(docker exec "$C_MAIN" sudo nft list table ip nat)"
assert_contains "$nft_ip4" 'oifname "CloudflareWARP" masquerade' "IPv4 NAT masquerade rule applied"

nft_ip6="$(docker exec "$C_MAIN" sudo nft list table ip6 nat)"
assert_contains "$nft_ip6" 'oifname "CloudflareWARP" masquerade' "IPv6 NAT masquerade rule applied"

socks_trace="$(docker exec "$C_MAIN" curl -fsS --max-time 6 --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace)"
assert_matches "$socks_trace" '^warp=(on|plus)$' "SOCKS5 proxy egress routes through WARP"

assert_cmd_ok "Custom WARP_TRACE_URL=https://1.1.1.1/cdn-cgi/trace succeeds" \
    docker exec -e WARP_TRACE_URL="https://1.1.1.1/cdn-cgi/trace" "$C_MAIN" bash /healthcheck/connected-to-warp.sh

assert_cmd_ok "fix-host-connectivity.sh runs cleanly (1st run)" \
    docker exec "$C_MAIN" bash /healthcheck/fix-host-connectivity.sh

assert_cmd_ok "fix-host-connectivity.sh is idempotent (2nd run)" \
    docker exec "$C_MAIN" bash /healthcheck/fix-host-connectivity.sh

# ---------------------------------------------------------------------------
# 2. Fast clean docker stop (interruptible sleep + shutdown())
# ---------------------------------------------------------------------------
log_section "Clean shutdown timing (docker stop)"

t0="$(date +%s)"
docker stop "$C_MAIN" >/dev/null
t1="$(date +%s)"
stop_secs=$((t1 - t0))
stop_rc="$(docker inspect -f '{{.State.ExitCode}}' "$C_MAIN")"

assert_eq "$stop_rc" "0" "docker stop exits cleanly with ExitCode=0"
if [ "$stop_secs" -le 4 ]; then
    pass "docker stop finished quickly (${stop_secs}s <= 4s)"
else
    fail "docker stop took too long (${stop_secs}s > 4s)"
fi

# ---------------------------------------------------------------------------
# 3. Warm restart preserves registration & reconnects
# ---------------------------------------------------------------------------
log_section "Warm restart persistence"

docker start "$C_MAIN" >/dev/null
if wait_for_healthy "$C_MAIN" 45; then
    pass "Warm restart reached healthy"
else
    fail "Warm restart failed to reach healthy" "$(docker logs --tail 20 "$C_MAIN" 2>&1)"
fi

assert_contains "$(docker logs --tail 40 "$C_MAIN" 2>&1)" \
    "Warp client already registered, skip registration" \
    "Warm restart skips re-registration"

# ---------------------------------------------------------------------------
# 4. Supervisor exits non-zero when warp-svc dies
# ---------------------------------------------------------------------------
log_section "Supervisor recovery: warp-svc death"

docker exec "$C_MAIN" sudo sh -c 'for p in /proc/[0-9]*/comm; do pid=$(basename "$(dirname "$p")"); if [ "$(cat "$p" 2>/dev/null)" = "warp-svc" ]; then kill -KILL "$pid"; fi; done'
if wait_for_exit "$C_MAIN" 15; then
    rc="$(docker inspect -f '{{.State.ExitCode}}' "$C_MAIN")"
    assert_eq "$rc" "1" "Killing warp-svc causes supervisor ExitCode=1"
    assert_contains "$(docker logs --tail 10 "$C_MAIN" 2>&1)" \
        "FATAL: warp-svc pipeline exited" \
        "Supervisor logs FATAL warp-svc pipeline exit"
else
    fail "Container did not exit within 15s after killing warp-svc"
fi

# ---------------------------------------------------------------------------
# 5. Supervisor propagates exit code when gost dies
# ---------------------------------------------------------------------------
log_section "Supervisor recovery: gost death"

docker start "$C_MAIN" >/dev/null
sleep 8
docker exec "$C_MAIN" sh -c 'for p in /proc/[0-9]*/comm; do pid=$(basename "$(dirname "$p")"); if [ "$(cat "$p" 2>/dev/null)" = "gost" ]; then kill -KILL "$pid"; fi; done'
if wait_for_exit "$C_MAIN" 15; then
    rc="$(docker inspect -f '{{.State.ExitCode}}' "$C_MAIN")"
    assert_eq "$rc" "137" "Killing gost propagates ExitCode=137"
    assert_contains "$(docker logs --tail 10 "$C_MAIN" 2>&1)" \
        "gost exited with status 137" \
        "Supervisor logs gost exit status"
else
    fail "Container did not exit within 15s after killing gost"
fi

# ---------------------------------------------------------------------------
# 6. Egress watchdog grace period, interval, and consecutive failure threshold
# ---------------------------------------------------------------------------
log_section "Supervisor recovery: egress watchdog"

docker run -d --name "$C_WD" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e EGRESS_GRACE_PERIOD=4 \
    -e EGRESS_CHECK_INTERVAL=2 \
    -e EGRESS_FAIL_THRESHOLD=3 \
    -e WARP_TRACE_URL="https://127.0.0.1:1/unreachable" \
    -v "${DATA_VOL}:/var/lib/cloudflare-warp" \
    "$IMAGE_TAG" >/dev/null

if wait_for_exit "$C_WD" 30; then
    wd_rc="$(docker inspect -f '{{.State.ExitCode}}' "$C_WD")"
    wd_logs="$(docker logs --tail 20 "$C_WD" 2>&1)"
    assert_eq "$wd_rc" "1" "Egress watchdog exits with ExitCode=1 after threshold"
    assert_contains "$wd_logs" "egress check failed (1/3)" "Watchdog logged failure 1/3"
    assert_contains "$wd_logs" "egress check failed (3/3)" "Watchdog logged failure 3/3"
    assert_contains "$wd_logs" "FATAL: egress check failed 3 consecutive times" "Watchdog logged FATAL threshold exit"
else
    fail "Egress watchdog container did not exit within 30s" "$(docker logs --tail 20 "$C_WD" 2>&1)"
fi

finish_suite "runtime"
