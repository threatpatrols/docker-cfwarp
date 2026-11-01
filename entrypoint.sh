#!/bin/bash

# exit when any command fails
set -e

# create a tun device if not exist
# allow passing device to ensure compatibility with Podman
if [ ! -e /dev/net/tun ]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    sudo chmod 600 /dev/net/tun
fi

# start dbus
sudo mkdir -p /run/dbus
if [ -f /run/dbus/pid ]; then
    sudo rm /run/dbus/pid
fi
sudo dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the warp-svc daemon with noise reduction
sudo warp-svc --accept-tos 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | grep -v DEBUG | grep -v NewNeighbour | grep -v MasqueTunnelStatsMessage &
# NOTE: with "a | b | c &" the $! is the PID of the LAST pipeline element (the
# final grep), not warp-svc itself. It is used as a liveness proxy: when
# warp-svc (or sed) dies the pipe closes and the grep exits.
SVC_PIPELINE_PID=$!

# sleep to wait for the daemon to start, default 2 seconds
sleep "$WARP_SLEEP"

# if /var/lib/cloudflare-warp/reg.json not exists, setup new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    # if /var/lib/cloudflare-warp/mdm.xml not exists or REGISTER_WHEN_MDM_EXISTS not empty, register the warp client
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        warp-cli --accept-tos registration new && echo "Warp client registered!"
        # if a license key is provided, register the license
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "License key found, registering license..."
            warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" && echo "Warp license registered!"
        fi
    fi
    # connect to the warp server
    warp-cli --accept-tos connect
else
    echo "Warp client already registered, skip registration"
fi

# disable qlog if DEBUG_ENABLE_QLOG is empty
if [ -z "$DEBUG_ENABLE_QLOG" ]; then
    warp-cli --accept-tos debug qlog disable
else
    warp-cli --accept-tos debug qlog enable
fi

# if WARP_ENABLE_NAT is provided, enable NAT and forwarding
if [ -n "$WARP_ENABLE_NAT" ]; then
    # switch to warp mode
    echo "[NAT] Switching to warp mode..."
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect

    # wait another seconds for the daemon to reconfigure
    sleep "$WARP_SLEEP"

    # enable NAT
    echo "[NAT] Enabling NAT..."
    sudo nft add table ip nat
    sudo nft add chain ip nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip mangle
    sudo nft add chain ip mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

    sudo nft add table ip6 nat
    sudo nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; }
    sudo nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
    sudo nft add table ip6 mangle
    sudo nft add chain ip6 mangle forward { type filter hook forward priority mangle \; }
    sudo nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
fi

# start the proxy under a small supervisor loop so a dead/hung warp-svc or gost
# exits the container and the restart policy recovers it, instead of gost (or
# the proxy at all) keeping an unhealthy container alive forever. Docker restart
# policies act on container exit, not on health status.
EGRESS_FAIL_THRESHOLD="${EGRESS_FAIL_THRESHOLD:-8}"
case "${EGRESS_FAIL_THRESHOLD}" in *[!0-9]*) EGRESS_FAIL_THRESHOLD=8 ;; esac

# unified shutdown: signal warp-svc (a rust daemon that ignores SIGPIPE, so
# killing the pipeline tail alone does not stop it), the pipeline and gost,
# then exit with the given status. procps is not installed, so the daemon is
# located via a /proc scan; the scan must skip its own sudo/sh processes.
shutdown() {
    rc="${1:-0}"
    set +e
    sudo sh -c 'for p in /proc/[0-9]*/cmdline; do
            pid=$(basename "$(dirname "$p")")
            [ "$pid" = "$$" ] && continue
            [ "$pid" = "$PPID" ] && continue
            grep -qa warp-svc "$p" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
        done' 2>/dev/null
    kill -TERM "$SVC_PIPELINE_PID" "$GOST_PID" 2>/dev/null
    wait "$GOST_PID"
    exit "$rc"
}

gost $GOST_ARGS &
GOST_PID=$!

# docker stop sends TERM to PID 1; exit cleanly (exit 0 so a deliberate stop
# never looks like a crash)
trap 'shutdown 0' TERM INT

EGRESS_FAIL_COUNT=0
while :; do
    if ! kill -0 "$SVC_PIPELINE_PID" 2>/dev/null; then
        echo "[supervisor] FATAL: warp-svc pipeline exited; exiting so the container restart policy recovers" >&2
        shutdown 1
    fi
    if ! kill -0 "$GOST_PID" 2>/dev/null; then
        set +e
        wait "$GOST_PID"
        GOST_EXIT=$?
        set -e
        echo "[supervisor] gost exited with status ${GOST_EXIT}; exiting" >&2
        shutdown "$GOST_EXIT"
    fi
    # egress watchdog: warp-svc can stay alive while the WARP tunnel is wedged,
    # silently falling back to the non-WARP route; exit after N consecutive
    # failed checks (0 disables the watchdog)
    if [ "${EGRESS_FAIL_THRESHOLD}" != "0" ]; then
        if bash /healthcheck/connected-to-warp.sh; then
            EGRESS_FAIL_COUNT=0
        else
            EGRESS_FAIL_COUNT=$((EGRESS_FAIL_COUNT + 1))
            echo "[supervisor] egress check failed (${EGRESS_FAIL_COUNT}/${EGRESS_FAIL_THRESHOLD})" >&2
            if [ "${EGRESS_FAIL_COUNT}" -ge "${EGRESS_FAIL_THRESHOLD}" ]; then
                echo "[supervisor] FATAL: egress check failed ${EGRESS_FAIL_COUNT} consecutive times; exiting so the container restart policy recovers" >&2
                shutdown 1
            fi
        fi
    fi
    sleep 5
done
