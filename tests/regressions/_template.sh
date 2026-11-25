#!/usr/bin/env bash
# Edge case:  <Short description of the bug or forgotten edge case>
# Root cause: <Why this broke or is easy to regress>
# Contract:   <Exact invariant that must hold going forward>
#
# Place offline tests in tests/regressions/static/NN-<slug>.sh
# Place live container tests in tests/regressions/runtime/NN-<slug>.sh
# Files matching _*.sh are ignored by the runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/../lib.sh"

cd "$REPO_ROOT"

log_section "Regression template"
skip "Copy this file to tests/regressions/{static,runtime}/NN-your-case.sh"

finish_suite "regression-template"
