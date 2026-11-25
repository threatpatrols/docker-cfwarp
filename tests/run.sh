#!/usr/bin/env bash
# Unified test runner for docker-cfwarp.
#
# Usage:
#   ./tests/run.sh [static|build|runtime|regressions|all] [options]
#
# Default (no suite specified): runs static (including static regressions) + build.
#
# Options:
#   --image <tag>      Docker image tag to build/test (default: docker-cfwarp:test)
#   --skip-build       Reuse an existing image instead of running docker build
#   --keep-image       Do not remove the test image on exit
#   --runtime          With 'regressions', also run live runtime regression tests
#   --filter <substr>  Only run regression files whose name contains <substr>
#   -h, --help         Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE=""
IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"
INCLUDE_RUNTIME_REGRESSIONS=0
FILTER=""
BUILT_FOR_RUN=0

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        static|build|runtime|regressions|all)
            SUITE="$1"
            shift
            ;;
        --image)
            IMAGE_TAG="${2:?--image requires a tag}"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --keep-image)
            KEEP_IMAGE=1
            shift
            ;;
        --runtime)
            INCLUDE_RUNTIME_REGRESSIONS=1
            shift
            ;;
        --filter)
            FILTER="${2:?--filter requires a substring}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

DEFAULT_MODE=0
if [ -z "$SUITE" ]; then
    SUITE="dev"
    DEFAULT_MODE=1
fi

export IMAGE_TAG

cleanup_image() {
    if [ "$BUILT_FOR_RUN" -eq 1 ] && [ "$KEEP_IMAGE" != "1" ]; then
        docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
    fi
}
trap cleanup_image EXIT

ensure_image() {
    if [ "$SKIP_BUILD" = "1" ]; then
        if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
            echo "ERROR: --skip-build set, but image '${IMAGE_TAG}' does not exist" >&2
            exit 1
        fi
        return 0
    fi
    docker build -t "$IMAGE_TAG" "${SCRIPT_DIR}/.." >/dev/null
    BUILT_FOR_RUN=1
}

run_regressions() {
    local scope="$1"
    local dir="${SCRIPT_DIR}/regressions/${scope}"
    [ -d "$dir" ] || return 0

    local matched=0
    local script=""
    local base=""
    for script in "${dir}"/*.sh; do
        [ -e "$script" ] || continue
        base="$(basename "$script")"
        # Ignore template/helper files starting with '_'
        case "$base" in _*) continue ;; esac
        if [ -n "$FILTER" ] && [[ "$base" != *"$FILTER"* ]]; then
            continue
        fi
        matched=$((matched + 1))
        bash "$script"
    done

    if [ -n "$FILTER" ] && [ "$matched" -eq 0 ]; then
        echo "Note: no ${scope} regressions matched --filter '${FILTER}'"
    fi
}

case "$SUITE" in
    static)
        bash "${SCRIPT_DIR}/test-static.sh"
        run_regressions static
        ;;
    build)
        SKIP_BUILD="$SKIP_BUILD" KEEP_IMAGE="$KEEP_IMAGE" bash "${SCRIPT_DIR}/test-build.sh"
        ;;
    runtime)
        ensure_image
        SKIP_BUILD=1 KEEP_IMAGE=1 bash "${SCRIPT_DIR}/test-runtime.sh"
        run_regressions runtime
        ;;
    regressions)
        run_regressions static
        if [ "$INCLUDE_RUNTIME_REGRESSIONS" -eq 1 ]; then
            ensure_image
            run_regressions runtime
        fi
        ;;
    dev)
        bash "${SCRIPT_DIR}/test-static.sh"
        run_regressions static
        SKIP_BUILD="$SKIP_BUILD" KEEP_IMAGE="$KEEP_IMAGE" bash "${SCRIPT_DIR}/test-build.sh"
        if [ "$DEFAULT_MODE" -eq 1 ]; then
            printf '\nTip: run "./tests/run.sh runtime" or "./tests/run.sh all" to also execute live WARP container & regression tests.\n'
        fi
        ;;
    all)
        bash "${SCRIPT_DIR}/test-static.sh"
        run_regressions static
        # Build once in test-build.sh and reuse the image across runtime + runtime regressions
        if [ "$SKIP_BUILD" != "1" ]; then
            BUILT_FOR_RUN=1
        fi
        SKIP_BUILD="$SKIP_BUILD" KEEP_IMAGE=1 bash "${SCRIPT_DIR}/test-build.sh"
        SKIP_BUILD=1 KEEP_IMAGE=1 bash "${SCRIPT_DIR}/test-runtime.sh"
        run_regressions runtime
        ;;
esac
