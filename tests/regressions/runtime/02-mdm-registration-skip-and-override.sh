#!/usr/bin/env bash
# Edge case:  mdm.xml suppresses consumer registration unless REGISTER_WHEN_MDM_EXISTS is set
# Root cause: Zero Trust / MDM deployments mount mdm.xml and must not create a
#             consumer registration by default, while users who explicitly set
#             REGISTER_WHEN_MDM_EXISTS expect consumer registration to proceed.
# Contract:   With mdm.xml mounted and no reg.json:
#             - REGISTER_WHEN_MDM_EXISTS unset -> skips `registration new`
#             - REGISTER_WHEN_MDM_EXISTS=1     -> registers consumer account

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

IMAGE_TAG="${IMAGE_TAG:-docker-cfwarp:test}"
RUN_ID="cfwarp-reg02-$$"
VOL_SKIP="${RUN_ID}-skip"
VOL_FORCE="${RUN_ID}-force"
C_SKIP="${RUN_ID}-c-skip"
C_FORCE="${RUN_ID}-c-force"
TMP_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "$C_SKIP" "$C_FORCE" >/dev/null 2>&1 || true
    docker volume rm -f "$VOL_SKIP" "$VOL_FORCE" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log_section "Regression: mdm.xml registration skip and REGISTER_WHEN_MDM_EXISTS override"

MDM_FILE="${TMP_DIR}/mdm.xml"
printf '<dict></dict>\n' > "$MDM_FILE"

docker volume create "$VOL_SKIP" >/dev/null
docker volume create "$VOL_FORCE" >/dev/null

# Case 1: mdm.xml exists, REGISTER_WHEN_MDM_EXISTS unset -> must NOT run consumer registration
docker run -d --name "$C_SKIP" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e EGRESS_FAIL_THRESHOLD=0 \
    -v "${VOL_SKIP}:/var/lib/cloudflare-warp" \
    -v "${MDM_FILE}:/var/lib/cloudflare-warp/mdm.xml:ro" \
    "$IMAGE_TAG" >/dev/null

sleep 8
logs_skip="$(docker logs "$C_SKIP" 2>&1 || true)"
if grep -qF "Warp client registered!" <<< "$logs_skip"; then
    fail "Unexpectedly ran consumer registration while mdm.xml existed" "$logs_skip"
else
    pass "Skipped consumer registration when mdm.xml exists and REGISTER_WHEN_MDM_EXISTS is empty"
fi

if docker run --rm -v "${VOL_SKIP}:/data:ro" --entrypoint /bin/bash "$IMAGE_TAG" -c 'test ! -f /data/reg.json'; then
    pass "No reg.json created when mdm.xml suppressed registration"
else
    fail "reg.json was unexpectedly created when mdm.xml existed"
fi

# Case 2: mdm.xml exists, REGISTER_WHEN_MDM_EXISTS=1 -> MUST register consumer account
docker run -d --name "$C_FORCE" \
    --device-cgroup-rule='c 10:200 rwm' \
    --cap-add=MKNOD --cap-add=AUDIT_WRITE --cap-add=NET_ADMIN \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e REGISTER_WHEN_MDM_EXISTS=1 \
    -e EGRESS_FAIL_THRESHOLD=0 \
    -v "${VOL_FORCE}:/var/lib/cloudflare-warp" \
    -v "${MDM_FILE}:/var/lib/cloudflare-warp/mdm.xml:ro" \
    "$IMAGE_TAG" >/dev/null

registered=0
for _ in $(seq 1 20); do
    logs_force="$(docker logs "$C_FORCE" 2>&1 || true)"
    if grep -qF "Warp client registered!" <<< "$logs_force"; then
        registered=1
        break
    fi
    sleep 2
done
assert_eq "$registered" "1" "REGISTER_WHEN_MDM_EXISTS=1 registered consumer account despite mdm.xml"

finish_suite "regression-02-mdm-registration-skip-and-override"
