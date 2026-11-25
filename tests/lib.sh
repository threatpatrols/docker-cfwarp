#!/usr/bin/env bash
# Shared test helpers for docker-cfwarp test suites.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_BLUE=""
    C_RESET=""
fi

log_section() {
    printf '\n%s==> %s%s\n' "$C_BLUE" "$1" "$C_RESET"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  %sPASS%s  %s\n' "$C_GREEN" "$C_RESET" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  %sFAIL%s  %s\n' "$C_RED" "$C_RESET" "$1" >&2
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2" >&2
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf '  %sSKIP%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local desc="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "expected: '${expected}', got: '${actual}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local desc="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then
        pass "$desc"
    else
        fail "$desc" "expected output to contain: '${needle}'"
    fi
}

assert_matches() {
    local haystack="$1"
    local pattern="$2"
    local desc="$3"
    if grep -qE -- "$pattern" <<< "$haystack"; then
        pass "$desc"
    else
        fail "$desc" "expected output to match regex: '${pattern}'"
    fi
}

assert_cmd_ok() {
    local desc="$1"
    shift
    local out=""
    if out=$("$@" 2>&1); then
        pass "$desc"
    else
        fail "$desc" "command failed: $* -> ${out}"
    fi
}

assert_cmd_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc" "expected failure but succeeded: $*"
    else
        pass "$desc"
    fi
}

finish_suite() {
    local suite_name="$1"
    printf '\n[%s] %d passed, %d failed, %d skipped\n' \
        "$suite_name" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    [ "$FAIL_COUNT" -eq 0 ]
}
