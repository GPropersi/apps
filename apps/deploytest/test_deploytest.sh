#!/usr/bin/env bash
# Offline test for the disposable deploytest app: the served files exist and the health file answers ok.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

fail=0
[ "$(cat www/healthz)" = "ok" ] || { echo "FAIL: www/healthz is not ok"; fail=1; }
[ -s www/index.html ] || { echo "FAIL: www/index.html missing"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: deploytest"
exit "$fail"
