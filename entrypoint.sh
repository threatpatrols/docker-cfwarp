#!/bin/bash

# exit when any command fails
set -e

SVC_PIPELINE_PID=""
GOST_PID=""
SLEEP_PID=""

# unified shutdown: signal warp-svc (a rust daemon that ignores SIGPIPE, so
# killing the pipeline tail alone does not stop it), the pipeline, any active
# sleep, and gost, then exit with the given status. procps is not installed, so
# the daemon is located via /proc/<pid>/comm (exact process name match).
shutdown() {
    rc="${1:-0}"
    trap - TERM INT
    set +e
    [ -n "${SLEEP_PID:-}" ] && kill -TERM "$SLEEP_PID" 2>/dev/null
    sudo sh -c 'for p in /proc/[0-9]*/comm; do
            pid=$(basename "$(dirname "$p")")
            [ "$pid" = "$$" ] && continue
            [ "$pid" = "$PPID" ] && continue
            [ "$(cat "$p" 2>/dev/null)" = "warp-svc" ] && kill -TERM "$pid" 2>/dev/null
        done' 2>/dev/null
    [ -n "${SVC_PIPELINE_PID:-}" ] && kill -TERM "$SVC_PIPELINE_PID" 2>/dev/null
    [ -n "${GOST_PID:-}" ] && kill -TERM "$GOST_PID" 2>/dev/null
    if [ -n "${GOST_PID:-}" ]; then
        wait "$GOST_PID" 2>/dev/null
    fi
    exit "$rc"
}

# sleep in a child process and wait on it so bash dispatches TERM/INT traps
# immediately instead of deferring them until the sleep finishes
interruptible_sleep() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

# docker stop sends TERM to PID 1; install early so stopping during setup
# exits cleanly (exit 0 so a deliberate stop never looks like a crash)
trap 'shutdown 0' TERM INT

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

# start the warp-svc daemon with unbuffered noise reduction
sudo warp-svc --accept-tos 2>&1 \
    | sed -u -e 's/\x1b\[[0-9;]*m//g' \
    | grep --line-buffered -vE 'DEBUG|NewNeighbour|MasqueTunnelStatsMessage' &
# NOTE: with "a | b | c &" the $! is the PID of the LAST pipeline element (the
# grep), not warp-svc itself. It is used as a liveness proxy: when warp-svc
# (or sed) dies the pipe closes and grep exits.
SVC_PIPELINE_PID=$!

# initial wait for the daemon to start (default 2s), then poll until its IPC
# socket is ready so slow hosts do not fail the first warp-cli invocation
WARP_SLEEP="${WARP_SLEEP:-2}"
case "${WARP_SLEEP}" in ''|*[!0-9]*) WARP_SLEEP=2 ;; esac
interruptible_sleep "$WARP_SLEEP"

warp_ready=0
for _ in $(seq 1 30); do
    if ! kill -0 "$SVC_PIPELINE_PID" 2>/dev/null; then
        echo "[entrypoint] FATAL: warp-svc pipeline exited during startup" >&2
        shutdown 1
    fi
    if [ -S /run/cloudflare-warp/warp_service ]; then
        warp_ready=1
        break
    fi
    interruptible_sleep 1
done
if [ "$warp_ready" -ne 1 ]; then
    echo "[entrypoint] WARNING: warp-svc socket not ready after 30s; continuing" >&2
fi

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
    # connect to the warp server (NAT mode connects after switching mode below)
    if [ -z "$WARP_ENABLE_NAT" ]; then
        warp-cli --accept-tos connect
    fi
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

    # wait for the daemon to reconfigure
    interruptible_sleep "$WARP_SLEEP"

    # enable NAT atomically and idempotently
    echo "[NAT] Enabling NAT..."
    sudo nft -f - <<'EOF'
add table ip nat
add chain ip nat WARP_NAT { type nat hook postrouting priority 100 ; }
flush chain ip nat WARP_NAT
add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade
add table ip mangle
add chain ip mangle forward { type filter hook forward priority mangle ; }
flush chain ip mangle forward
add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu

add table ip6 nat
add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 ; }
flush chain ip6 nat WARP_NAT
add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade
add table ip6 mangle
add chain ip6 mangle forward { type filter hook forward priority mangle ; }
flush chain ip6 mangle forward
add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu
EOF
fi

# start the proxy under a small supervisor loop so a dead/hung warp-svc or gost
# exits the container and the restart policy recovers it, instead of gost
# keeping an unhealthy container alive forever. Docker restart policies act on
# container exit, not on health status.
EGRESS_FAIL_THRESHOLD="${EGRESS_FAIL_THRESHOLD:-8}"
case "${EGRESS_FAIL_THRESHOLD}" in ''|*[!0-9]*) EGRESS_FAIL_THRESHOLD=8 ;; esac

EGRESS_CHECK_INTERVAL="${EGRESS_CHECK_INTERVAL:-5}"
case "${EGRESS_CHECK_INTERVAL}" in ''|*[!0-9]*) EGRESS_CHECK_INTERVAL=5 ;; esac
[ "${EGRESS_CHECK_INTERVAL}" -ge 1 ] || EGRESS_CHECK_INTERVAL=5

EGRESS_GRACE_PERIOD="${EGRESS_GRACE_PERIOD:-15}"
case "${EGRESS_GRACE_PERIOD}" in ''|*[!0-9]*) EGRESS_GRACE_PERIOD=15 ;; esac

read -r -a GOST_ARGS_ARR <<< "${GOST_ARGS:--L :1080}"
gost "${GOST_ARGS_ARR[@]}" &
GOST_PID=$!

LIVENESS_INTERVAL=5
EGRESS_FAIL_COUNT=0
NEXT_EGRESS_CHECK=$((SECONDS + EGRESS_GRACE_PERIOD))
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
    if [ "${EGRESS_FAIL_THRESHOLD}" != "0" ] && [ "$SECONDS" -ge "$NEXT_EGRESS_CHECK" ]; then
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
        NEXT_EGRESS_CHECK=$((SECONDS + EGRESS_CHECK_INTERVAL))
    fi
    sleep_secs="$LIVENESS_INTERVAL"
    if [ "${EGRESS_FAIL_THRESHOLD}" != "0" ]; then
        until_egress=$((NEXT_EGRESS_CHECK - SECONDS))
        if [ "$until_egress" -lt "$sleep_secs" ]; then
            sleep_secs="$until_egress"
        fi
    fi
    [ "$sleep_secs" -ge 1 ] || sleep_secs=1
    interruptible_sleep "$sleep_secs"
done
