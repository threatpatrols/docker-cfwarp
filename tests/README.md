# Tests

Lightweight, dependency-free test suites for verifying changes to `docker-cfwarp` during development and CI, including an auto-discovered `regressions/` directory for capturing edge cases so they are never forgotten.

## Quick start

```bash
# Default: fast offline static/unit tests + static regressions + Docker build verification
./tests/run.sh

# Full suite (static + static regressions + build + live runtime + runtime regressions)
./tests/run.sh all

# Individual suites
./tests/run.sh static
./tests/run.sh build
./tests/run.sh runtime

# Run only regression tests (add --runtime for live container regressions, --filter to narrow)
./tests/run.sh regressions
./tests/run.sh regressions --runtime
./tests/run.sh regressions --runtime --filter disconnect
```

## Suites

| Path | Scope | Requirements |
|---|---|---|
| `tests/test-static.sh` | Shell syntax (`bash -n`, `sh -n`), `shellcheck` (if installed; enforce with `REQUIRE_SHELLCHECK=1`), `ipcalc` unit tests, mocked `connected-to-warp.sh` & `index.sh` dispatch tests | `bash`, `sh` |
| `tests/regressions/static/*.sh` | Auto-discovered offline edge-case regressions (blackhole curl timeout, POSIX `ipcalc` octal/mask edge cases, mocked `fix-host-connectivity.sh` IPv4/IPv6/idempotency, repo contract & doc drift checks) | `bash`, `sh`, `python3` (for TCP blackhole test) |
| `tests/test-build.sh` | Builds the Docker image, verifies metadata, `ENV` defaults, `HEALTHCHECK`, `root:root` ownership on `gost`, stripped desktop bloat, `ldd` linkage for `warp-svc`/`warp-cli`, binary smoke checks, and unbuffered `sed`/`grep` support | `docker` |
| `tests/test-runtime.sh` | Boots throwaway containers/volumes and verifies cold boot with `WARP_ENABLE_NAT=1`, IPC socket, `/proc/<pid>/comm`, IPv4/IPv6 `nft` NAT rules, SOCKS5 `warp=on` egress, `WARP_TRACE_URL`, `fix-host-connectivity.sh` idempotency, sub-4s clean `docker stop`, warm restart persistence, supervisor recovery on `warp-svc`/`gost` death, and egress watchdog grace/threshold behavior | `docker`, `NET_ADMIN` + tun cgroup support, outbound internet |
| `tests/regressions/runtime/*.sh` | Auto-discovered live container edge-case regressions (deliberate `warp-cli disconnect` preserved across restarts, `mdm.xml` skip + `REGISTER_WHEN_MDM_EXISTS` override, `docker stop` mid-setup without SIGKILL, custom `GOST_ARGS` + `DEBUG_ENABLE_QLOG` + invalid numeric env fallbacks, `EGRESS_FAIL_THRESHOLD=0` escape hatch) | `docker`, `NET_ADMIN` + tun cgroup support, outbound internet |

## Adding a new edge-case regression test

Whenever you hit a subtle bug or edge case, add a standalone test so it is automatically picked up by `./tests/run.sh`, `bash -n`, and CI `shellcheck`:

1. Copy the template into either `static/` (fast, offline — preferred whenever possible) or `runtime/` (requires a live container):
   ```bash
   cp tests/regressions/_template.sh tests/regressions/static/05-my-edge-case.sh
   # or:
   cp tests/regressions/_template.sh tests/regressions/runtime/06-my-edge-case.sh
   chmod +x tests/regressions/static/05-my-edge-case.sh
   ```
2. Update the `source` path to `${SCRIPT_DIR}/../../lib.sh` and fill in the `Edge case:`, `Root cause:`, and `Contract:` header comments so future you knows *why* the test exists.
3. Run just your new test while iterating:
   ```bash
   ./tests/run.sh regressions --filter my-edge-case
   # or for a runtime regression:
   ./tests/run.sh regressions --runtime --filter my-edge-case
   ```

## CI vs local tests

- **GitHub Actions** ([ci.yml](../.github/workflows/ci.yml) and [build-publish.yml](../.github/workflows/build-publish.yml)) runs `./tests/run.sh static` (with `REQUIRE_SHELLCHECK=1`) and `./tests/run.sh build` (against the Buildx-loaded image). Live WARP runtime tests (`runtime`) are **intentionally excluded** from workflow runners so CI never boots `warp-svc` or connects to Cloudflare WARP.
- **Locally** run `./tests/run.sh all` (or `./tests/run.sh runtime`) before publishing changes that touch `entrypoint.sh`, `healthcheck/`, or `Dockerfile`.

## Useful options

```bash
# Keep the built test image for manual inspection
./tests/run.sh build --keep-image

# Reuse an existing image tag without rebuilding
./tests/run.sh runtime --image docker-cfwarp:test --skip-build

# Test building with pinned versions
WARP_VERSION=2026.8.2115.0 GOST_VERSION=2.12.0 ./tests/run.sh build
```
