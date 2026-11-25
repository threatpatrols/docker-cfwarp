#!/bin/bash

set -euo pipefail

trace_url="${WARP_TRACE_URL:-https://cloudflare.com/cdn-cgi/trace}"

# --max-time caps the whole request; without it a black-holed tunnel can stall
# the Docker HEALTHCHECK and the entrypoint supervisor's egress watchdog
trace_output="$(curl -fsS --max-time 4 "$trace_url")" || exit 1
grep -qE '^warp=(plus|on)$' <<< "$trace_output" || exit 1
exit 0
