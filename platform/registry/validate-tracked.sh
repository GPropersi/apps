#!/usr/bin/env bash
# validate-tracked.sh: validate every tracked apps/*/app.yaml of the git repo in the current directory.
# Passes vacuously when there are none. This is what `make lint` runs.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
git ls-files -z -- 'apps/*/app.yaml' | xargs -0 -r "$here/validate-app-yaml.sh" || exit 1
