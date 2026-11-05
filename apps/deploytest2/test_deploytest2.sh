#!/usr/bin/env bash
# Offline test for the disposable deploytest2 app: the served files exist and the health file answers ok.
# While the temporary fail-on-main marker exists it also fails on main only (ci-deploy Step 12 isolation proof).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

fail=0
[ "$(cat www/healthz)" = "ok" ] || { echo "FAIL: www/healthz is not ok"; fail=1; }
[ -s www/index.html ] || { echo "FAIL: www/index.html missing"; fail=1; }
if [ -e fail-on-main ] && [ "${GITHUB_REF:-}" = refs/heads/main ]; then
  echo "FAIL: fail-on-main marker present on main"
  fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS: deploytest2"
exit "$fail"
