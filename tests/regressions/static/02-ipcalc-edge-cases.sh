#!/usr/bin/env bash
# Edge case:  POSIX ipcalc replacement edge cases (octal leading zeros, /31, /32
#             Hostroute vs Network output contract, malformed inputs)
# Root cause: Slim image dropped perl ipcalc for a minimal /bin/sh script; POSIX
#             arithmetic treats leading zeros as octal and fix-host-connectivity
#             depends on the exact 'Network:' vs 'Hostroute:' output format.
# Contract:   healthcheck/ipcalc handles /0../32 cleanly without octal bugs and
#             rejects all malformed CIDRs with non-zero exit status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

log_section "Regression: healthcheck/ipcalc edge cases"

run_ipcalc() {
    sh "${REPO_ROOT}/healthcheck/ipcalc" "$@"
}

# Leading-zero octets (010 must be decimal 10, not octal 8; 008/009 must not fail as invalid octal)
assert_eq "$(run_ipcalc -n 010.008.009.025/024)" "Network:   10.8.9.0/24" "Leading zeros in octets and prefix parsed as decimal"
# Point-to-point /31 and non-byte-aligned masks
assert_eq "$(run_ipcalc -n 10.0.0.3/31)"         "Network:   10.0.0.2/31"  "/31 point-to-point mask"
assert_eq "$(run_ipcalc -n 192.168.13.254/22)"   "Network:   192.168.12.0/22" "Non-byte-aligned /22 mask"
assert_eq "$(run_ipcalc -n 255.255.255.255/1)"   "Network:   128.0.0.0/1"  "/1 high-bit mask (no signed 32-bit overflow)"
# Classic perl ipcalc contract: /32 prints Hostroute, never Network
assert_eq "$(run_ipcalc -n 172.16.0.9/32)"       "Hostroute: 172.16.0.9"   "/32 reports Hostroute (matches classic ipcalc)"
assert_eq "$(run_ipcalc -n 0.0.0.0/0)"           "Network:   0.0.0.0/0"    "0.0.0.0/0 works"

# Malformed inputs must fail cleanly
assert_cmd_fail "Rejects trailing dot"       run_ipcalc -n 10.0.0.1./24
assert_cmd_fail "Rejects empty octet"        run_ipcalc -n 10..0.1/24
assert_cmd_fail "Rejects negative prefix"    run_ipcalc -n 10.0.0.1/-1
assert_cmd_fail "Rejects empty prefix"       run_ipcalc -n 10.0.0.1/
assert_cmd_fail "Rejects double slash"       run_ipcalc -n 10.0.0.1/24/8

finish_suite "regression-02-ipcalc-edge-cases"
