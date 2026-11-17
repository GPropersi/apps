#!/usr/bin/env bash
# notifs-exchange-name.sh: the registrar-mode `name` the notifs-app action takes for one platform app.
#
#   platform/ci/notifs-exchange-name.sh <app>     prints the app name with - replaced by _ (birthdays, my_app)
#
# The server derives the app id as the registrar prefix plus this name, so the result is the shared helper's app_id
# (platform/lib/notifs-app-id.sh) minus its `apps_` prefix. Exit 1 (nothing printed) for a refused name, 2 on usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# SC1091: sourced by relative path.
# shellcheck source=../lib/notifs-app-id.sh disable=SC1091
. "$here/../lib/notifs-app-id.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: notifs-exchange-name.sh <app>" >&2
  exit 2
fi

id="$(notifs_app_id "$1")" || { echo "notifs-exchange-name: refused app name" >&2; exit 1; }
printf '%s\n' "${id#"$NOTIFS_APP_ID_PREFIX"}"
