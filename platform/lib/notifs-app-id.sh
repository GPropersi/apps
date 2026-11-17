#!/usr/bin/env bash
# notifs-app-id.sh: the 4irl-notifs app_id of a platform app, sourced (not run).
#
#   . platform/lib/notifs-app-id.sh
#   notifs_app_id <app-name>     prints `apps_<name with - replaced by _>`; returns 1 (prints nothing) for a refused name
#
# The Go twin lives in the app template (templates/go-react/internal/platform). Both are tested against one shared
# fixture, templates/go-react/internal/platform/testdata/notifs-app-ids.txt (name TAB app_id, or REFUSED), so the two
# implementations cannot drift. The result always matches ^[a-z0-9][a-z0-9_]{0,62}$.

NOTIFS_APP_ID_PREFIX='apps_'
NOTIFS_APP_NAME_RE='^[a-z][a-z0-9-]{1,30}$'
NOTIFS_APP_ID_RE='^[a-z0-9][a-z0-9_]{0,62}$'

notifs_app_id() {
  local name="${1-}" id
  [[ "$name" =~ $NOTIFS_APP_NAME_RE ]] || return 1
  id="${NOTIFS_APP_ID_PREFIX}${name//-/_}"
  [[ "$id" =~ $NOTIFS_APP_ID_RE ]] || return 1
  printf '%s\n' "$id"
}
