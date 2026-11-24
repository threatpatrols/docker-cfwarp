#!/bin/bash

# --max-time caps the whole request; without it a black-holed tunnel can stall
# the Docker HEALTHCHECK and the entrypoint supervisor's egress watchdog
curl -fsS --max-time 4 "https://cloudflare.com/cdn-cgi/trace" | grep -qE "warp=(plus|on)" || exit 1
exit 0
