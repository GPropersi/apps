# platform/registry/

The per-app registry: every app carries one `apps/<name>/app.yaml`, and the validator rejects anything the
schema does not list (a typo is an error, never ignored).

| File | Role |
|---|---|
| `validate-app-yaml.sh <file>...` | Validator. Exit 0 valid, 1 invalid (one `file: reason` line per problem), 2 usage. |
| `validate-tracked.sh` | Validates every tracked `apps/*/app.yaml` of the current repo; passes with none. Run by `make lint`. |
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

## Dropped on purpose

Per-app `db` and `redis` booleans and a per-app connection limit are not in the schema: nothing reads them yet,
and the connection limit is a platform-wide constant.
