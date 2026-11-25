#!/usr/bin/env bash
# Docker build and image artifact verification tests (no privileges or WARP registration needed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "$REPO_ROOT"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"
BUILT_BY_SCRIPT=0

cleanup() {
    if [ "$BUILT_BY_SCRIPT" -eq 1 ] && [ "$KEEP_IMAGE" != "1" ]; then
        docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI not found in PATH"
    finish_suite "build"
fi

# ---------------------------------------------------------------------------
# 1. Build image (unless SKIP_BUILD=1)
# ---------------------------------------------------------------------------
log_section "Docker image build (${IMAGE_TAG})"

if [ "$SKIP_BUILD" = "1" ]; then
    if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        pass "Reusing pre-built image ${IMAGE_TAG} (SKIP_BUILD=1)"
    else
        fail "SKIP_BUILD=1 set, but image ${IMAGE_TAG} does not exist"
        finish_suite "build"
    fi
else
    build_cmd=(docker build -t "$IMAGE_TAG")
    if [ -n "${WARP_VERSION:-}" ]; then
        build_cmd+=(--build-arg "WARP_VERSION=${WARP_VERSION}")
    fi
    if [ -n "${GOST_VERSION:-}" ]; then
        build_cmd+=(--build-arg "GOST_VERSION=${GOST_VERSION}")
    fi
    if [ -n "${BASE_IMAGE:-}" ]; then
        build_cmd+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
    fi
    build_cmd+=(.)

    if "${build_cmd[@]}"; then
        BUILT_BY_SCRIPT=1
        pass "docker build succeeded (${IMAGE_TAG})"
    else
        fail "docker build failed (${IMAGE_TAG})"
        finish_suite "build"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Image configuration & metadata
# ---------------------------------------------------------------------------
log_section "Image metadata, ENV defaults, and HEALTHCHECK"

img_user="$(docker inspect -f '{{.Config.User}}' "$IMAGE_TAG")"
assert_eq "$img_user" "warp" "Container user is 'warp'"

img_entrypoint="$(docker inspect -f '{{json .Config.Entrypoint}}' "$IMAGE_TAG")"
assert_eq "$img_entrypoint" '["/entrypoint.sh"]' "Entrypoint is ['/entrypoint.sh']"

img_hc="$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$IMAGE_TAG")"
assert_contains "$img_hc" "/healthcheck/index.sh" "HEALTHCHECK invokes /healthcheck/index.sh"

img_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE_TAG")"
assert_contains "$img_env" "GOST_ARGS=-L :1080" "Default ENV GOST_ARGS=-L :1080"
assert_contains "$img_env" "WARP_SLEEP=2" "Default ENV WARP_SLEEP=2"
assert_contains "$img_env" "EGRESS_FAIL_THRESHOLD=8" "Default ENV EGRESS_FAIL_THRESHOLD=8"
assert_contains "$img_env" "EGRESS_CHECK_INTERVAL=5" "Default ENV EGRESS_CHECK_INTERVAL=5"
assert_contains "$img_env" "EGRESS_GRACE_PERIOD=15" "Default ENV EGRESS_GRACE_PERIOD=15"
assert_contains "$img_env" "WARP_TRACE_URL=https://cloudflare.com/cdn-cgi/trace" "Default ENV WARP_TRACE_URL"

# ---------------------------------------------------------------------------
# 3. Container filesystem, binaries, permissions, and library linkage
# ---------------------------------------------------------------------------
log_section "Image filesystem, binaries, and ldd checks"

run_in_image() {
    docker run --rm --entrypoint /bin/bash "$IMAGE_TAG" -c "$1"
}

assert_eq "$(run_in_image 'id -un')" "warp" "Runtime effective user is warp"
assert_eq "$(run_in_image 'cat /home/warp/.local/share/warp/accepted-tos.txt')" "yes" "WARP TOS pre-accepted"

assert_cmd_ok "Required scripts and binaries are executable" \
    run_in_image 'test -x /entrypoint.sh && test -x /healthcheck/index.sh && test -x /healthcheck/connected-to-warp.sh && test -x /healthcheck/fix-host-connectivity.sh && test -x /usr/local/bin/ipcalc && test -x /usr/local/bin/gost && test -x /usr/bin/warp-svc && test -x /usr/bin/warp-cli'

assert_cmd_ok "No duplicate /healthcheck/ipcalc left in image" \
    run_in_image 'test ! -e /healthcheck/ipcalc'

assert_eq "$(run_in_image 'stat -c %U:%G /usr/local/bin/gost')" "root:root" "/usr/local/bin/gost owned by root:root"

assert_cmd_ok "Desktop WARP bloat removed from slim image" \
    run_in_image 'test ! -e /usr/lib/warp && test ! -e /usr/bin/warp-desktop && test ! -e /usr/bin/warp-taskbar'

# shellcheck disable=SC2016
assert_cmd_ok "warp-svc and warp-cli have zero unresolved shared libraries (ldd)" \
    run_in_image 'for b in /usr/bin/warp-svc /usr/bin/warp-cli; do out="$(ldd "$b")" || exit 1; ! printf "%s\n" "$out" | grep -F "not found"; done'

gost_ver="$(run_in_image 'gost -V 2>&1')"
assert_matches "$gost_ver" '^gost [0-9]+\.[0-9]+\.[0-9]+' "gost -V runs cleanly (${gost_ver%%$'\n'*})"

warp_ver="$(run_in_image 'warp-cli --version 2>&1')"
assert_matches "$warp_ver" 'warp-cli [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "warp-cli --version runs cleanly (${warp_ver%%$'\n'*})"

assert_eq "$(run_in_image 'ipcalc -n 192.168.1.42/24')" "Network:   192.168.1.0/24" "In-image ipcalc works"

assert_cmd_ok "Container sed -u and grep --line-buffered work" \
    run_in_image 'printf "INFO keep\nDEBUG drop\n" | sed -u "s/INFO/OK/" | grep --line-buffered -vE "DEBUG|NewNeighbour" | grep -qxF "OK keep"'

finish_suite "build"
