#!/usr/bin/env bash
# Edge case:  fix-host-connectivity.sh nft/ip-rule generation, /32 handling,
#             IPv6 link-local filtering, and idempotency
# Root cause: Unquoted variables, loose grep matching, missing CloudflareWARP
#             interface, /32 Hostroute output from ipcalc, and IPv6 link-local
#             routes (fe80::/64) can break or duplicate firewall/routing rules.
# Contract:   fix-host-connectivity.sh skips when CloudflareWARP is absent,
#             handles /32 + IPv4 + global IPv6 while ignoring fe80::/lo/WARP,
#             and emits zero mutations when rules already exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

log_section "Regression: fix-host-connectivity.sh edge cases (mocked)"

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "$MOCK_BIN"
LOG_FILE="${TMP_DIR}/mutations.log"

# Provide real ipcalc on PATH
cp "${REPO_ROOT}/healthcheck/ipcalc" "${MOCK_BIN}/ipcalc"
chmod +x "${MOCK_BIN}/ipcalc"

# Mock sudo (executes command directly with mocked PATH)
cat > "${MOCK_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "${MOCK_BIN}/sudo"

# Mock nft
cat > "${MOCK_BIN}/nft" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
    printf '%s\n' "${MOCK_NFT_TABLE:-}"
    exit 0
fi
printf 'nft %s\n' "$*" >> "${MOCK_LOG}"
EOF
chmod +x "${MOCK_BIN}/nft"

# Mock ip
cat > "${MOCK_BIN}/ip" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--json" ] && [ "$2" = "address" ]; then
    printf '%s\n' "${MOCK_IP_ADDR_JSON}"
    exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "--json" ] && [ "$3" = "route" ]; then
    printf '%s\n' "${MOCK_IP6_ROUTE_JSON:-[]}"
    exit 0
fi
if [ "$1" = "rule" ] && [ "$2" = "list" ]; then
    printf '%s\n' "${MOCK_IP4_RULES:-}"
    exit 0
fi
if [ "$1" = "-6" ] && [ "$2" = "rule" ] && [ "$3" = "list" ]; then
    printf '%s\n' "${MOCK_IP6_RULES:-}"
    exit 0
fi
printf 'ip %s\n' "$*" >> "${MOCK_LOG}"
EOF
chmod +x "${MOCK_BIN}/ip"

run_fix() {
    : > "$LOG_FILE"
    PATH="${MOCK_BIN}:${PATH}" \
        MOCK_LOG="$LOG_FILE" \
        MOCK_IP_ADDR_JSON="$1" \
        MOCK_IP6_ROUTE_JSON="${2:-[]}" \
        MOCK_NFT_TABLE="${3:-}" \
        MOCK_IP4_RULES="${4:-}" \
        MOCK_IP6_RULES="${5:-}" \
        bash "${REPO_ROOT}/healthcheck/fix-host-connectivity.sh"
}

# Case 1: CloudflareWARP absent -> skip cleanly with zero mutations
addr_no_warp='[{"ifname":"lo","addr_info":[]},{"ifname":"eth0","addr_info":[{"family":"inet","local":"172.18.0.2","prefixlen":16}]}]'
out1="$(run_fix "$addr_no_warp")"
assert_contains "$out1" "CloudflareWARP not started, skip." "Skips cleanly when CloudflareWARP interface is absent"
assert_eq "$(cat "$LOG_FILE")" "" "No nft/ip mutations when CloudflareWARP is absent"

# Case 2: Normal IPv4 CIDR + /32 IPv4 + global IPv6 + fe80:: link-local (must ignore fe80::, lo, CloudflareWARP)
addr_mixed='[
  {"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
  {"ifname":"CloudflareWARP","addr_info":[{"family":"inet","local":"172.16.0.2","prefixlen":32}]},
  {"ifname":"eth0","addr_info":[
    {"family":"inet","local":"172.18.0.5","prefixlen":16},
    {"family":"inet","local":"10.99.0.7","prefixlen":32}
  ]}
]'
routes6='[
  {"dev":"lo","dst":"::1"},
  {"dev":"CloudflareWARP","dst":"2606:4700::/64"},
  {"dev":"eth0","dst":"fe80::/64"},
  {"dev":"eth0","dst":"fd42:4242:2189::/64"}
]'
run_fix "$addr_mixed" "$routes6" "" "" "" >/dev/null
muts="$(cat "$LOG_FILE")"
assert_contains "$muts" "nft add rule inet cloudflare-warp input ip saddr 172.18.0.0/16 accept" "Adds IPv4 /16 input nft rule"
assert_contains "$muts" "nft add rule inet cloudflare-warp output ip daddr 172.18.0.0/16 accept" "Adds IPv4 /16 output nft rule"
assert_contains "$muts" "ip rule add to 172.18.0.0/16 lookup main priority 10" "Adds IPv4 /16 routing rule"
assert_contains "$muts" "nft add rule inet cloudflare-warp input ip saddr 10.99.0.7/32 accept" "Handles /32 IPv4 without ipcalc Network mismatch"
assert_contains "$muts" "nft add rule inet cloudflare-warp input ip6 saddr fd42:4242:2189::/64 accept" "Adds global/ULA IPv6 input nft rule"
assert_contains "$muts" "ip -6 rule add to fd42:4242:2189::/64 lookup main priority 10" "Adds global/ULA IPv6 routing rule"

if grep -qF "fe80:" <<< "$muts" || grep -qF "172.16.0.2" <<< "$muts" || grep -qF "127.0.0" <<< "$muts"; then
    fail "Unexpectedly added rule for fe80::, lo, or CloudflareWARP" "$muts"
else
    pass "Excludes fe80:: link-local, lo, and CloudflareWARP addresses"
fi

# Case 3: Idempotency when rules already exist
existing_nft='
table inet cloudflare-warp {
    chain input {
        ip saddr 172.18.0.0/16 accept
        ip saddr 10.99.0.7/32 accept
        ip6 saddr fd42:4242:2189::/64 accept
    }
    chain output {
        ip daddr 172.18.0.0/16 accept
        ip daddr 10.99.0.7/32 accept
        ip6 daddr fd42:4242:2189::/64 accept
    }
}
'
existing_ip4='10:	from all to 172.18.0.0/16 lookup main
10:	from all to 10.99.0.7/32 lookup main'
existing_ip6='10:	from all to fd42:4242:2189::/64 lookup main'

run_fix "$addr_mixed" "$routes6" "$existing_nft" "$existing_ip4" "$existing_ip6" >/dev/null
assert_eq "$(cat "$LOG_FILE")" "" "Idempotent: zero mutations when nft and ip rules already exist"

finish_suite "regression-03-fix-host-connectivity-mocked"
