#!/bin/bash

# exit when any command fails
set -euo pipefail

interfaces=$(ip --json address | jq -r '
    .[] |
    select(.ifname != "lo") |
    .ifname
')

# if CloudflareWARP not started, abort
if ! grep -qxF "CloudflareWARP" <<< "$interfaces"; then
    echo "[fix-host-connectivity] CloudflareWARP not started, skip."
    exit 0
fi

# get excluded IPv4 networks
networks=()
while IFS= read -r cidr; do
    [ -z "$cidr" ] && continue
    if [[ "$cidr" == */32 ]]; then
        networks+=("$cidr")
    else
        net="$(ipcalc -n "$cidr" | awk '/^Network:/ {print $2}')"
        [ -n "$net" ] && networks+=("$net")
    fi
done < <(ip --json address | jq -r '
    .[] |
    select((.ifname != "lo") and (.ifname != "CloudflareWARP")) |
    .addr_info[] |
    select(.family == "inet") |
    "\(.local)/\(.prefixlen)"
')

# get excluded IPv6 networks directly from kernel connected routes (skip link-local)
networks6=()
while IFS= read -r net6; do
    [ -z "$net6" ] && continue
    networks6+=("$net6")
done < <(ip -6 --json route show proto kernel 2>/dev/null | jq -r '
    .[] |
    select((.dev != "lo") and (.dev != "CloudflareWARP")) |
    .dst |
    select((. != null) and (startswith("fe80:") | not))
')

# if no networks found, abort
if [ "${#networks[@]}" -eq 0 ] && [ "${#networks6[@]}" -eq 0 ]; then
    echo "[fix-host-connectivity] WARNING: No networks found, abort."
    exit 0
fi

nft_rules="$(sudo nft list table inet cloudflare-warp)"
ip4_rules="$(ip rule list)"

# add excluded IPv4 networks to nft table cloudflare-warp and routing table
for network in "${networks[@]}"; do
    if ! grep -qF "ip saddr $network accept" <<< "$nft_rules"; then
        echo "[fix-host-connectivity] Adding $network to input chain of nft table cloudflare-warp."
        sudo nft add rule inet cloudflare-warp input ip saddr "$network" accept
    fi
    if ! grep -qF "ip daddr $network accept" <<< "$nft_rules"; then
        echo "[fix-host-connectivity] Adding $network to output chain of nft table cloudflare-warp."
        sudo nft add rule inet cloudflare-warp output ip daddr "$network" accept
    fi
    if ! grep -qF "to $network lookup main" <<< "$ip4_rules"; then
        # stop packet from using routing table created by CloudflareWARP
        echo "[fix-host-connectivity] Adding routing rule for $network."
        sudo ip rule add to "$network" lookup main priority 10
    fi
done

# add excluded IPv6 networks to nft table cloudflare-warp and routing table
if [ "${#networks6[@]}" -gt 0 ]; then
    ip6_rules="$(ip -6 rule list)"
    for network6 in "${networks6[@]}"; do
        if ! grep -qF "ip6 saddr $network6 accept" <<< "$nft_rules"; then
            echo "[fix-host-connectivity] Adding $network6 to input chain of nft table cloudflare-warp."
            sudo nft add rule inet cloudflare-warp input ip6 saddr "$network6" accept
        fi
        if ! grep -qF "ip6 daddr $network6 accept" <<< "$nft_rules"; then
            echo "[fix-host-connectivity] Adding $network6 to output chain of nft table cloudflare-warp."
            sudo nft add rule inet cloudflare-warp output ip6 daddr "$network6" accept
        fi
        if ! grep -qF "to $network6 lookup main" <<< "$ip6_rules"; then
            echo "[fix-host-connectivity] Adding IPv6 routing rule for $network6."
            sudo ip -6 rule add to "$network6" lookup main priority 10
        fi
    done
fi
