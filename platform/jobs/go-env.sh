#!/usr/bin/env bash
# go-env.sh: source it (do not run it) from a script that runs go for platform/jobs.
#
#   . "$here/go-env.sh"
#
# Exports GOTOOLCHAIN=go<GO_VERSION> so the exact pinned release runs whether the system Go is newer or older
# (>= 1.21; the first run downloads the toolchain into the module cache). The shared system Go is never modified.
# Returns 1, naming both values, when go is missing or the resolved version differs from GO_VERSION. Callers use
# `set -e`, so a failing source stops them loudly; nothing here ever skips.
#
# The go.mod "toolchain" line is only a minimum under GOTOOLCHAIN=auto, so it never forces the version by itself;
# platform/lint/check-go.sh checks it for equality with GO_VERSION.

_goenv_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_VERSION="$(tr -d '[:space:]' < "$_goenv_dir/GO_VERSION")"
if [ -z "$GO_VERSION" ]; then
  echo "go-env: $_goenv_dir/GO_VERSION is empty" >&2
  return 1
fi
export GOTOOLCHAIN="go$GO_VERSION"

if ! command -v go > /dev/null 2>&1; then
  echo "go-env: go is not installed (need Go >= 1.21 on PATH to fetch go$GO_VERSION)" >&2
  return 1
fi

_goenv_have="$(cd "$_goenv_dir" && go version 2>&1 | sed -n 's/^go version go\([^ ]*\) .*/\1/p')"
if [ "$_goenv_have" != "$GO_VERSION" ]; then
  echo "go-env: go version mismatch: GO_VERSION wants $GO_VERSION, 'go version' in $_goenv_dir resolved ${_goenv_have:-nothing} (GOTOOLCHAIN=$GOTOOLCHAIN; the first run needs network to fetch the toolchain)" >&2
  return 1
fi
unset _goenv_dir _goenv_have
