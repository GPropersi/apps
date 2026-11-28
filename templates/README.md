# templates/

Starting points for scaffolding new apps. `go-react/` is the default: a Go server (chi, pgx + sqlc, goose) embedding a
Vite + React page, with the Cloudflare Access identity, jobs, Postgres and Redis helpers in `internal/platform/`.

## Scaffolding an app

```
make app-new NAME=<name> PURPOSE="<one line>" [TEMPLATE=go-react] [OWNER=gpropersi]
```

`platform/scaffold/app-new.sh` is offline (no network, ssh or `platform new-db` call; CI's first deploy creates the
database). It validates the name with the registry validator (name rule, `reserved-names.txt`, Postgres identifier rule),
refuses an existing `apps/<name>/` or a name already declared by another `app.yaml`, copies the template into a temp
directory under `apps/`, replaces the placeholder app name `tmplgoreact`, writes `owner` and `purpose` into `app.yaml`,
and runs `validate-app-yaml.sh`, `check-apps.sh` and `check-template-copies.sh` against a throwaway scratch git work tree
(those lints read tracked files only). Only if all pass does it rename the directory into `apps/<name>/`; any failure
leaves `apps/` exactly as it was. `git add` the new directory before `make lint`, which reads tracked files.

The placeholder is `tmplgoreact`. It appears in `app.yaml`, the Go module path, `package.json`, `web/index.html` (title),
`web/src/appName.ts` and the Go import paths. In Go files the package identifier becomes `app_<name>` (hyphens as
underscores), so a name such as `go` or `map` never collides with a Go keyword. The string must not appear anywhere else
in a template: `app-new` refuses a scaffold that still carries it, and `internal/platform/` must never name it.

## Files a new app rewrites

A scaffold is a working sample (a notes list and one `add-note` job), not a skeleton. The first real app replaces
the sample, and these starter files carry assumptions about it:

- `migrations/00001_init.sql`, `sql/queries.sql` and the generated `internal/app/db/` (run `make app-sqlc APP=<name>`):
  the sample `items` and `job_runs` tables and queries.
- `internal/app/server.go` routes and handlers, and `internal/app/jobs.go` (`Funcs()` and the `add-note` handler);
  `app.yaml` `jobs[]` must keep matching `Funcs()` (`platform.VerifyJobs` fails startup otherwise).
- `internal/app/fakes_test.go` (`fakeStore` implements the sample `db.Querier`; `fakeQueue.Enqueue` and
  `fakeQueue.EnqueueUnique` accept only `add-note`) and the tests that use them (`server_test.go`, `jobs_test.go`, `run_test.go`).
- `test_image.sh`: its job and table assertions (`/_jobs/add-note`, `select count(*) from items`, the `items` rows) and
  the `/api/me` probe.
- `web/src/` pages and tests, `web/index.html`'s title, and `web/public/favicon.svg` (the placeholder icon).

- `app.yaml` `notifs`: absent (false) in the template. Set `notifs: true` to turn on the phone-notification routes and
  the "Phone notifications" section of the web page (see "Reaching 4irl-notifs"); with it absent the routes answer 404
  and the section is hidden.

`internal/platform/` is not rewritten: it is shared and byte-identical (see below).

## Reaching 4irl-notifs (`notifs: true`)

An app that sends notifications (phone push, or a person's Discord or webhook destinations) opts in with `notifs: true`
in `app.yaml` (default false). Only those apps get a `dak_` key written to the host, and it arrives as the files
`/run/platform/secrets/notifs-key`, `notifs-access-client-id`, `notifs-access-client-secret` and `notifs-base-url`
after the platform's manual notifs-exchange workflow has run. The files do not exist on a first deploy, and the app
must be healthy without them.

Use `platform.NewNotifsClient(platform.NotifsSecretsDir, appID)` with `appID` from `platform.NotifsAppID(<app name>)`
(`birthdays` -> `apps_birthdays`). It re-reads the files on every call, so a rotated key needs no restart; construct it
freely, and call `Configured()` (no network) only where a missing key should fail the run, such as a scheduled scan,
before queueing work. Errors are `ErrNotifsUnconfigured`, `ErrNotifsRetryable` (network or 5xx) and `*NotifsError`
(`Status`, delivery-api's message); it logs the operation, status and duration, never a key, email or URL.

### The phone-notification flow (`notifs: true`)

With `notifs: true` the template also ships a ready phone and destinations flow, so a new app needs no notifs code of
its own. `platform.DeclaredApp(appYAML)` reads `name` and `notifs` from the embedded `app.yaml` (an unparsable file is
logged and treated as false: fail closed). The routes below are registered only when the flag is true; otherwise the
router answers the standard JSON 404. `GET /api/me` reports `{email, notifs, phone?}`, and the web page shows the
section only when `notifs` is true. Every `/api` response of the template (including 401s, and whether or not `notifs` is true) is `Cache-Control: no-store`.

| Route | Purpose |
|---|---|
| `GET /api/notify/destinations` | the person's Discord and webhook destinations (never the URL) |
| `POST /api/notify/ntfy` | set up the phone: setup link plus a one-time password |
| `POST /api/notify/ntfy/reset` | generate a new password (409 `ntfy_not_set_up` before setup) |
| `POST /api/notify/ntfy/test` | send a test to the phone (30 s cooldown, 429 `rate_limited`) |
| `POST /api/notify/destinations` | add a destination (max 10; a webhook signing secret is shown once) |
| `POST /api/notify/destinations/{id}/check`, `/test` | re-check or test one destination (`destination_stale` when it was rejected) |
| `DELETE /api/notify/destinations/{id}` | remove a destination |

The pure helpers live in `internal/platform/` (`notifs_flow.go`: `Notifier`, `NotifsSetupURL`, `TestLimiter`,
`TestMessage`, `SendWithPublisher`; `notifs_destination.go`: `ValidDestination`, `DestinationHint`; `declared_app.go`:
`DeclaredApp`), so they stay byte-identical across apps. The handlers, SQL and wire shapes are the app's own
(`internal/app/`). Per-person state lives in `notifs_users` (the person's ntfy user id, keyed by lowercase email) and
`destinations` (kind, label, hint, stale flag; scoped by email), created by migration `00002_phone_notifications.sql`.
The table exists in every scaffold; it is only used when the flag is on.

If provisioning succeeds but the local write fails, the route answers 500 and the one-time password is lost: tap
"Set up phone" again, then "Generate a new password".

`notifs: true` alone is not enough in production: the host-side notifs key must exist first (the manual notifs-exchange
flow, see `platform/ci/notifs-apps.sh` and `apps/README.md`). Until then the app stays healthy and the notify routes
answer 500 `notify_unavailable`. The scaffold test (`platform/scaffold/test_app_new.sh`) only proves that a `notifs: true`
scaffold builds and passes its Go tests; it does not exercise the key.

Other helpers a scheduled job needs: `Jobs.Queue` (the app's queue client, set by `Run`) with `EnqueueUnique(ctx, job,
key, payload, ttl)` to queue at most one job per key (key matches `[A-Za-z0-9._:-]{1,128}`, ttl 1s to 7 days, else
`ErrInvalidDedupeKey`; the key is stored at `<prefix>jobs:dedupe:<job>:<key>`; an ambiguous LPUSH failure can
double-enqueue, so the consumer must be idempotent), and `platform.ScheduleZone()` (America/Los_Angeles, embedded
zoneinfo) to decide "today" for a daily job.

## Updating the shared helpers

`templates/go-react/internal/platform/` is copied byte-for-byte into every go-react app (an app's Docker build context
is `apps/<name>/` only, so it cannot import from `templates/`). `platform/lint/check-template-copies.sh` (run by
`make lint`) fails when any app's copy differs from the template's, listing the differing files. To change a helper:
edit the template, then in every go-react app run `rm -r apps/<name>/internal/platform && cp -R
templates/go-react/internal/platform apps/<name>/internal/platform`. `check-go.sh` also requires each template and app
Dockerfile's `golang` builder (tag and digest) to equal `platform/jobs/Dockerfile`'s.

The go-react template supports `access` absent or `family` only (it validates one shared Access audience);
`check-apps.sh` refuses `access: public` and `access: restricted` for a `template: go-react` app.

`make app-sqlc APP=<name>` (or `TEMPLATE=<name>`) regenerates an app's or template's sqlc Go code with the pinned
generator image.

## Tests and CI

The template's own tests are `templates/<name>/test_*.sh` (`test_go.sh` heavy; `test_web.sh`, `test_sqlc.sh` and
`test_image.sh` docker; each carries its `# test-class:` marker). `platform/test/run.sh` discovers them beside
`platform/**/test_*.sh` and `apps/<name>/test_*.sh`, so `make test` (every push to `main`) runs them. On a pull request
`make test-changed` resolves a `templates/**` diff through `platform/test/areas.map` to the `scaffold`, `templates` and
`lint` areas: the template unit tests, the scaffold tests (including the live one, which scaffolds an app and runs it)
and lint, not the full suite. The map also lists `templates` wherever it lists `scaffold`, because those tests read the
same inputs (`go-env.sh`, `GO_VERSION`, `new-db.sh`, `deploy.sh`). The required `ci` check always runs (no workflow-level
`paths:` filter) and decides inside the job.

A scaffolded app is a normal `apps/<name>/`: a change under it selects only that app's `apps/<name>/test_*.sh`, and
`app-deploy-one.yml`'s `test` job runs `make test-app APP=<name>` on the stock runner image. That needs only what the
image provides: Docker (the web, sqlc and image tests run Node, sqlc and the build in pinned containers) and its
preinstalled Go, which downloads the pinned toolchain through `GOTOOLCHAIN`. No Node on the host is needed. The `ci` job's
Go cache key also hashes `templates/*/go.sum` and `apps/*/go.sum`.

Every template that supports background jobs implements the language-neutral contract in
[`platform/jobs/CONTRACT.md`](../platform/jobs/CONTRACT.md): the `enqueue(job, payload)` helper and the
`POST /_jobs/<name>` handler, and passes its conformance checklist.
