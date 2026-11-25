#!/usr/bin/env bash
# Edge case:  Silent contract & documentation drift across entrypoint, Dockerfile,
#             and docs
# Root cause: Small edits easily re-introduce stale upstream image names,
#             undocumented ENV vars, buffered log pipelines, or late signal traps.
# Contract:   Key architectural invariants stay intact and every Dockerfile ENV
#             is documented in README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../../lib.sh"

cd "$REPO_ROOT"

log_section "Regression: repo contracts & documentation alignment"

# 1. Entrypoint invariants
head_line="$(head -n 1 entrypoint.sh)"
assert_eq "$head_line" "#!/bin/bash" "entrypoint.sh keeps #!/bin/bash shebang"

trap_line="$(grep -n "trap 'shutdown 0' TERM INT" entrypoint.sh | head -n 1 | cut -d: -f1)"
svc_line="$(grep -n "sudo warp-svc" entrypoint.sh | head -n 1 | cut -d: -f1)"
if [ -n "$trap_line" ] && [ -n "$svc_line" ] && [ "$trap_line" -lt "$svc_line" ]; then
    pass "TERM/INT trap installed (line ${trap_line}) before launching warp-svc (line ${svc_line})"
else
    fail "TERM/INT trap must be installed before launching warp-svc" "trap=${trap_line:-none}, svc=${svc_line:-none}"
fi

assert_contains "$(cat entrypoint.sh)" "sed -u" "warp-svc log pipeline uses unbuffered sed -u"
assert_contains "$(cat entrypoint.sh)" "grep --line-buffered" "warp-svc log pipeline uses line-buffered grep"

# 2. Dockerfile invariants
dockerfile_text="$(cat Dockerfile)"
assert_contains "$dockerfile_text" "USER warp" "Dockerfile preserves USER warp model"
assert_contains "$dockerfile_text" "CMD /healthcheck/index.sh" "Dockerfile preserves HEALTHCHECK CMD /healthcheck/index.sh"
assert_contains "$dockerfile_text" "sha256sum -c" "Dockerfile verifies gost SHA256 checksum"
assert_contains "$dockerfile_text" "ldd" "Dockerfile checks warp-svc/warp-cli shared library linkage"

# 3. Every ENV declared in Dockerfile must be documented in README.md
readme_text="$(cat README.md)"
missing_envs=()
while IFS= read -r env_name; do
    [ -z "$env_name" ] && continue
    if ! grep -qF "\`${env_name}\`" <<< "$readme_text"; then
        missing_envs+=("$env_name")
    fi
done < <(awk '/^ENV / { split($2, a, "="); print a[1] }' Dockerfile)

if [ "${#missing_envs[@]}" -eq 0 ]; then
    pass "All Dockerfile ENV variables are documented in README.md"
else
    fail "Undocumented Dockerfile ENV(s) in README.md" "${missing_envs[*]}"
fi

# 4. No stale upstream caomingjun/warp image references in active configs/docs
stale_refs="$(grep -rn 'caomingjun/warp' docker-compose.yml README.md \
    docs/healthcheck.md docs/host-connectivity.md docs/masque.md \
    docs/nat-gateway.md docs/podman.md docs/proxy-mode.md \
    docs/warp-connector.md docs/zero-trust.md 2>/dev/null || true)"
assert_eq "$stale_refs" "" "No stale caomingjun/warp image references in active docs/compose"

# 5. GitHub Actions workflow invariants
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    for wf in .github/workflows/*.yml; do
        assert_cmd_ok "Valid YAML syntax: ${wf}" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$wf"
    done
else
    skip "PyYAML not installed locally; skipping YAML parse check on .github/workflows/*.yml"
fi

unpinned_actions="$(grep -rnE '^\s*uses:\s+' .github/workflows/*.yml | grep -vE '@[0-9a-f]{40}(\s|$)' || true)"
assert_eq "$unpinned_actions" "" "All GitHub Actions uses: references are pinned to 40-char commit SHAs"

live_warp_in_ci="$(grep -rnE 'test-runtime\.sh|run\.sh\s+(runtime|all)|--runtime' .github/workflows/*.yml || true)"
assert_eq "$live_warp_in_ci" "" "Workflows do not execute live WARP runtime tests on GitHub runners"

finish_suite "regression-04-docs-and-contract-checks"
