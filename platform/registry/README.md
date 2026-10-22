# platform/registry/

The per-app registry: every app carries one `apps/<name>/app.yaml`, and the validator rejects anything the
schema does not list (a typo is an error, never ignored).

| File | Role |
|---|---|
| `validate-app-yaml.sh <file>...` | Validator. Exit 0 valid, 1 invalid (one `file: reason` line per problem), 2 usage. |
| `validate-tracked.sh` | Validates every tracked `apps/*/app.yaml` of the current repo; passes with none. Run by `make lint`. |
| `app-ls.sh [--live-from FILE]` | App listing behind `make app-ls` (registry only, offline) and `make host-app-ls HOST=<alias>` (registry joined with `platform ls` output). |
| `reserved-names.txt` | Refused app names. Also read on the host by `platform new-db`. |
| `app.yaml.example` | A valid example. Copy it to `apps/<name>/app.yaml` and edit. |
| `test_*.sh` | Offline tests (`make test`). |

The file is written in the small YAML subset read by `platform/lib/yaml-subset.sh`: 2-space indentation, plain
`key: value` lines, no flow collections, no inline comments, quoted values without backslashes or inner quotes.

## Fields (`schema_version: 1`)

| Key | Required | Rule |
|---|---|---|
| `schema_version` | yes | Exactly `1`, unquoted. A newer version fails closed. |
| `name` | yes | `^[a-z][a-z0-9-]{1,30}$`, equal to the parent directory name (the file must be a regular file, a symlinked `app.yaml` is refused), not in `reserved-names.txt`. Its Postgres identifier (`-` becomes `_`) must not start with `pg_` or equal `postgres`, `template0`, `template1` or `public`. |
| `owner` | yes | A short handle, `^[a-z][a-z0-9-]{1,30}$`. Never an email address (the repo is public). |
| `purpose` | yes | One line, not blank or only whitespace, at most 120 characters. |
| `template` | yes | One of `go-react`, `go-htmx`, `fastapi-react`, `flask`, `node-hono`. |
| `memory_cap` | yes | A number of MiB with the unit `m`, from `16m` to `512m`. |
| `port` | yes | Integer 1 to 65535, unquoted. |
| `health_path` | no | Starts with `/`; only letters, digits and `. _ ~ / % -` after it. |
| `access` | no | `family` (default when absent), `public` or `restricted`. Records intent only: no email lists belong in the file. |
| `jobs` | no | A non-empty list of maps (below). |

Unknown top-level keys, duplicate keys and wrong types are errors.

### `jobs[]`

| Key | Required | Rule |
|---|---|---|
| `name` | yes | `^[a-z][a-z0-9_-]{0,62}$`, unique within the app. |
| `schedule` | no | A **quoted** 5-field cron string (`"0 7 * * *"`). Omit for a job that is only enqueued. |
| `timeout` | yes | A number with the unit `s`, `m` or `h`, greater than zero and at most 1 hour. |
| `catch_up` | no | `true` or `false` (unquoted), default `false`. |

Unknown keys inside a job are errors.

## `platform ls` output contract

`platform ls` (the dispatcher subcommand, run on the host; no registry there) prints stable TSV, **one row per
app**, sorted by app name, three columns: `app<TAB>state<TAB>health`. Step 13 consumes it.

| Column | Values |
|---|---|
| `app` | The `platform.app` label value, matching `^[a-z][a-z0-9-]{1,30}$`. |
| `state` | `running` only if every container of the app (stopped ones included) is running. Otherwise the most severe non-running state: `restarting` > `dead` > `exited` > `paused` > `created`. A state outside that list (for example `removing`) ranks above all and is printed verbatim. The result never depends on `docker ps` ordering. |
| `health` | The worst across the app's containers, read from the `Status` text: `unhealthy` > `starting` > `healthy`, else `none`. |

Empty output with exit 0 means no labelled containers. A `docker ps` failure or an unparseable row exits 1 with an
error line on stderr and no rows, so an empty rc-0 result never hides a failure.

## `app-ls.sh` table

Columns `APP OWNER TEMPLATE MEM ACCESS STATE`. STATE is `-` offline; with live input it is `<state>` or
`<state> (<health>)` when health is not `none` (`running (unhealthy)`), `not deployed` for a registered app with no
live row, and `UNREGISTERED` for a live app with no `app.yaml` (listed, exit 1). An invalid `app.yaml` or malformed
live input prints an error, exits 1 and prints no table.

## Dropped on purpose

Per-app `db` and `redis` booleans and a per-app connection limit are not in the schema: nothing reads them yet,
and the connection limit is a platform-wide constant.
