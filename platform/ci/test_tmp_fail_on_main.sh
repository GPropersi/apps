#!/usr/bin/env bash
# TEMPORARY (ci-deploy Step 12): fails only on main, to show a failing platform test turns the ci check red without
# blocking the app deploys. Removed by the next rollout PR.
set -uo pipefail

if [ "${GITHUB_REF:-}" = refs/heads/main ]; then
  echo "FAIL: temporary platform test fails on main"
  exit 1
fi
echo "PASS: temporary platform test (not on main)"
