#!/usr/bin/env bash
# Fast offline static checks and unit tests for scripts in docker-cfwarp.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

cd "$REPO_ROOT"

TMP_TEST_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_TEST_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Shell syntax & linting
# ---------------------------------------------------------------------------
log_section "Shell syntax & lint"

mapfile -t REGRESSION_SCRIPTS < <(find tests/regressions -type f -name '*.sh' | sort)

assert_cmd_ok "bash -n entrypoint.sh" bash -n entrypoint.sh
assert_cmd_ok "bash -n healthcheck/*.sh" bash -n healthcheck/*.sh
assert_cmd_ok "bash -n tests/*.sh" bash -n tests/*.sh
if [ "${#REGRESSION_SCRIPTS[@]}" -gt 0 ]; then
    assert_cmd_ok "bash -n tests/regressions/**/*.sh" bash -n "${REGRESSION_SCRIPTS[@]}"
fi
assert_cmd_ok "sh -n healthcheck/ipcalc" sh -n healthcheck/ipcalc

if command -v shellcheck >/dev/null 2>&1; then
    assert_cmd_ok "shellcheck entrypoint.sh healthcheck/* tests/" \
        shellcheck -x entrypoint.sh healthcheck/*.sh healthcheck/ipcalc tests/*.sh "${REGRESSION_SCRIPTS[@]}"
elif [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
    fail "shellcheck required (REQUIRE_SHELLCHECK=1) but not installed"
else
    skip "shellcheck not installed locally (set REQUIRE_SHELLCHECK=1 to enforce)"
fi

# ---------------------------------------------------------------------------
# 2. healthcheck/ipcalc unit tests
# ---------------------------------------------------------------------------
log_section "healthcheck/ipcalc unit tests"

run_ipcalc() {
    sh "${REPO_ROOT}/healthcheck/ipcalc" "$@"
}

assert_eq "$(run_ipcalc -n 192.168.1.42/24)"     "Network:   192.168.1.0/24"  "ipcalc /24 network"
assert_eq "$(run_ipcalc -n 172.18.0.5/16)"       "Network:   172.18.0.0/16"   "ipcalc /16 network"
assert_eq "$(run_ipcalc -n 10.20.30.40/8)"       "Network:   10.0.0.0/8"      "ipcalc /8 network"
assert_eq "$(run_ipcalc -n 192.168.10.6/30)"     "Network:   192.168.10.4/30" "ipcalc /30 network"
assert_eq "$(run_ipcalc -n 10.0.0.1/32)"         "Hostroute: 10.0.0.1"        "ipcalc /32 hostroute"
assert_eq "$(run_ipcalc -n 10.0.0.1)"            "Hostroute: 10.0.0.1"        "ipcalc bare IP treated as /32"
assert_eq "$(run_ipcalc -n 10.0.0.1/0)"          "Network:   0.0.0.0/0"       "ipcalc /0 default network"
assert_eq "$(run_ipcalc -n 010.008.001.009/024)" "Network:   10.8.1.0/24"     "ipcalc strips leading zeros (no octal)"

assert_cmd_fail "ipcalc rejects octet > 255"     run_ipcalc -n 999.0.0.1/24
assert_cmd_fail "ipcalc rejects prefix > 32"     run_ipcalc -n 10.0.0.1/33
assert_cmd_fail "ipcalc rejects 3-octet IP"      run_ipcalc -n 10.0.1/24
assert_cmd_fail "ipcalc rejects 5-octet IP"      run_ipcalc -n 10.0.0.1.2/24
assert_cmd_fail "ipcalc rejects non-numeric IP"  run_ipcalc -n a.b.c.d/24
assert_cmd_fail "ipcalc rejects missing -n flag" run_ipcalc 10.0.0.1/24
assert_cmd_fail "ipcalc rejects extra args"      run_ipcalc -n 10.0.0.1/24 extra

# ---------------------------------------------------------------------------
# 3. healthcheck/connected-to-warp.sh unit tests (mocked curl)
# ---------------------------------------------------------------------------
log_section "healthcheck/connected-to-warp.sh unit tests"

MOCK_BIN="${TMP_TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"
MOCK_ARGS_LOG="${TMP_TEST_DIR}/curl-args.log"

cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${MOCK_ARGS_LOG}"
if [ -n "${MOCK_CURL_RC:-}" ] && [ "${MOCK_CURL_RC}" != "0" ]; then
    exit "${MOCK_CURL_RC}"
fi
printf '%s\n' "${MOCK_CURL_BODY:-}"
EOF
chmod +x "${MOCK_BIN}/curl"

run_trace_check() {
    PATH="${MOCK_BIN}:${PATH}" \
        MOCK_ARGS_LOG="$MOCK_ARGS_LOG" \
        MOCK_CURL_BODY="$1" \
        MOCK_CURL_RC="${2:-0}" \
        WARP_TRACE_URL="${3:-}" \
        bash "${REPO_ROOT}/healthcheck/connected-to-warp.sh"
}

assert_cmd_ok   "connected-to-warp passes on warp=on"   run_trace_check $'fl=1\nwarp=on\ngateway=off'
assert_cmd_ok   "connected-to-warp passes on warp=plus" run_trace_check $'fl=1\nwarp=plus\ngateway=off'
assert_cmd_fail "connected-to-warp fails on warp=off"   run_trace_check $'fl=1\nwarp=off\ngateway=off'
assert_cmd_fail "connected-to-warp rejects partial key" run_trace_check $'mywarp=on\nwarp=off'
assert_cmd_fail "connected-to-warp fails on curl error" run_trace_check "" 28

run_trace_check $'warp=on' 0 "https://1.1.1.1/cdn-cgi/trace"
recorded_args="$(cat "$MOCK_ARGS_LOG")"
assert_contains "$recorded_args" "--max-time 4" "connected-to-warp bounds curl with --max-time 4"
assert_contains "$recorded_args" "https://1.1.1.1/cdn-cgi/trace" "connected-to-warp honors WARP_TRACE_URL"

# ---------------------------------------------------------------------------
# 4. healthcheck/index.sh dispatch unit tests
# ---------------------------------------------------------------------------
log_section "healthcheck/index.sh dispatch unit tests"

HC_STUB_DIR="${TMP_TEST_DIR}/hc"
mkdir -p "$HC_STUB_DIR"
cp "${REPO_ROOT}/healthcheck/index.sh" "${HC_STUB_DIR}/index.sh"

MARKER="${TMP_TEST_DIR}/fix-ran"
cat > "${HC_STUB_DIR}/connected-to-warp.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${HC_STUB_DIR}/fix-host-connectivity.sh" <<EOF
#!/usr/bin/env bash
touch "${MARKER}"
EOF

rm -f "$MARKER"
BETA_FIX_HOST_CONNECTIVITY="" bash "${HC_STUB_DIR}/index.sh"
if [ ! -e "$MARKER" ]; then
    pass "index.sh skips fix-host-connectivity when BETA_FIX_HOST_CONNECTIVITY is unset"
else
    fail "index.sh ran fix-host-connectivity when BETA_FIX_HOST_CONNECTIVITY was unset"
fi

BETA_FIX_HOST_CONNECTIVITY="1" bash "${HC_STUB_DIR}/index.sh"
if [ -e "$MARKER" ]; then
    pass "index.sh runs fix-host-connectivity when BETA_FIX_HOST_CONNECTIVITY=1"
else
    fail "index.sh did not run fix-host-connectivity when BETA_FIX_HOST_CONNECTIVITY=1"
fi

finish_suite "static"
