# platform/jobs: the shared jobs runner

One small Go service (`platform-jobs-runner`) that runs every app's scheduled jobs (from `jobs:` in
`app.yaml`) and queued jobs, calling each app's internal `POST /_jobs/<name>`. Design, contracts and step
order: `~/code/plans/apps/open/jobs-runner/jobs-runner.md`.

This file covers the Go packages under `internal/`, the runner binary, the image and compose service, and the
installer (`platform/host/install-jobs.sh`, `make host-jobs`). The app-side contract (`enqueue()`, `/_jobs`) is
[`CONTRACT.md`](CONTRACT.md); `internal/contractdoc` tests it against the runner's constants.

## Files

| File | Job |
|---|---|
| `cmd/runner/` | the binary: `runner` mode (default) wires scheduler, queue consumer, status goroutine and the Discord notifier (used as both alerter and notifier); `healthcheck` mode exits 0 only when `runner.tsv` `heartbeat_at` is under 60s old |
| `Dockerfile` | multi-stage build, builder and final image pinned by digest (`GO_VERSION` is the builder tag), `CGO_ENABLED=0`, user `65532:65532`; the `COPY` list names the runner files explicitly |
| `compose.yaml` | project `platform-jobs`, container `platform-jobs-runner`, unlabelled, on `platform` only, read-only root, `mem_limit 48m` |
| `testapp/`, `Dockerfile.testapp` | a throwaway app implementing the `/_jobs` handler, started only by `install-jobs.sh testapp-up` |
| `test_go.sh`, `test_jobs_live.sh`, `test_jobs_stack.sh` | Go unit tests, real-Redis test, compose and Dockerfile policy test |

## Host paths and the two files you create

The installer never writes these two files; create them as root before `install` (it lists them if missing). Each
create command is guarded with `test -e ||`, so pasting it again never overwrites an existing file, and the webhook is
typed into an editor (never into a command line, where shell history and `ps` would keep it):

    sudo install -d -m 0755 -o root -g root /etc/platform
    sudo test -e /etc/platform/jobs.env || sudo install -m 0640 -o root -g 64324 /dev/null /etc/platform/jobs.env
    sudoedit /etc/platform/jobs.env
    sudo test -e /etc/platform/jobs-redis.password || { sudo install -m 0640 -o root -g 64324 /dev/null /etc/platform/jobs-redis.password && openssl rand -hex 24 | sudo tee /etc/platform/jobs-redis.password >/dev/null; }

`jobs.env` holds one line, `DISCORD_WEBHOOK=https://...`. A file that exists with the wrong owner or mode is fixed in
place: `sudo chown root:64324 <file> && sudo chmod 0640 <file>`.

`jobs-redis.password` may end in one newline (exactly one is stripped everywhere it is used). Both files are
single-file mounts read once at runner start, so a change to either needs `make host-jobs HOST=<alias> ARGS=install`,
which recreates the container (`verify` fails until you do).

State lives in bind mounts, never named volumes: `/var/lib/platform/jobs-status` and `/var/lib/platform/jobs-state`
(`65532:65532`), `/opt/platform/jobs` (installer inputs record). Offline: the Pi cannot rebuild the image without the
image registry and the Go module proxy (the `install` precondition checks them when a build is needed); with the image
for the current source hash present, no network is needed.

## Run model

One container, four goroutines: the status writer (15s heartbeat), the Discord notifier, the scheduler and the queue
consumer. Any of them returning before shutdown stops the whole runner with exit code 1, so the restart policy brings
it back instead of leaving it half-dead. On `SIGTERM` the scheduler and consumer wait for in-flight runs (up to the
longest job timeout, 1h), then the notifier is stopped last so alerts from runs that finished meanwhile are sent. The
compose service therefore sets `stop_grace_period: 65m`; `docker stop` or a recreate (`install` after a changed input)
can take that long when a run is in flight, and docker only sends `SIGKILL` after it. Scheduled runs cut off by a
`SIGKILL` are lost; queued ones are recovered from `processing` at the next start.

## Alerts, `install` and `verify`

Alerts go to the Discord webhook in `jobs.env` (see "Discord alerts" below). `install` checks every precondition before
changing anything (network, data stack, Redis admin login, `window.env`, the two input files, job-secrets root, host
paths; free disk and the build network only when an image build will run), builds the image when the source hash
changed, applies the Redis `runner` user (when the password hash or the live rule differs), creates the host dirs,
(re)creates the container and, once it is healthy, writes `/opt/platform/jobs/inputs.sha256`. A second `install` prints
only `already:` lines. `verify` FAILs on image drift, ACL drift, path modes, an unhealthy container, a heartbeat older
than 120s, a labelled container, a missing backup directory mount, inputs newer than the record (stale single-file
mount), `redis_state=invalid`, `window_state=invalid`, and a missing, empty or not six-field `runner.tsv`; it only WARNs
on `redis_state=down` and `config_state=invalid`. The usual repair for any FAIL is `install`.

## Test app

`make host-jobs HOST=<alias> ARGS=testapp-up` (needs `platform new-db jobstest` first) builds the throwaway test app,
registers `jobstest` (a registry `app.yaml` generated from the same job list as the container's `JOBS_DECLARED`) and
starts it on the `platform` network with the `platform.app=jobstest` label. `ARGS=testapp-down` removes the container,
the registry file and the image, and prints the commands to remove the secret and Redis user by hand. Neither runs from
`install`, `verify` or `status`. A container named `platform-jobs-testapp` without that label is never replaced or removed.

## Admin notes

- **Dead list.** As Redis admin, `LRANGE <app>:jobs:dead 0 -1` shows the last 100 dead records of an app. On the
  host: `sudo docker exec platform-data-redis sh -c 'REDISCLI_AUTH="$(cat /etc/platform/redis-admin.password)" exec redis-cli --user admin --no-auth-warning LRANGE <app>:jobs:dead 0 -1'`
  (the password is read inside the container, never on an argv).
- **Orphan keys.** The runner never enumerates Redis. After an app is removed or disabled, its `<app>:jobs:queue`,
  `:processing`, `:delayed` and `:dead` keys stay. As admin, inspect with `EXISTS`/`LLEN`/`ZCARD` per key, and delete
  with `DEL <app>:jobs:queue <app>:jobs:processing <app>:jobs:delayed <app>:jobs:dead` once nothing should run.
  Use `redis-cli` through the admin snippet in `install-data.sh`, never a password on argv.
- **Reserved namespace.** `<app>:jobs:*` is reserved inside each app prefix; apps must not use it for other data.
- **1 MB limit.** The shared Redis rejects any single value above 1 MB for every client.
- **Redis OOM.** A Redis `OOM` that stalls the queue is alert-and-log only. It is not shown in `runner.tsv`,
  `verify` or the status page.
- **Head-of-line.** Queued items of one app are taken in order; a head that is in flight or held by the window rule
  blocks that app's later items (never other apps).
- **Window overlap.** A `Persistent=true` catch-up backup that starts outside the window can overlap with jobs.

## Packages

| Package | Job |
|---|---|
| `clock` | the only place that touches wall time, timers and randomness (`Clock`, `Fake`, `Jitter`, `NewULID`) |
| `cron` | 5-field cron parsing and `Next` in a zone (Vixie day rule, DST rules) |
| `registry` | reads `<root>/<app>/app.yaml`; an invalid file disables that app only |
| `window` | reads the backup window file, fail closed; `Refuses(fire, timeout)` is the window rule |
| `dispatch` | the HTTP call to an app, outcome classes, masked error text |
| `mask` | secret and control-character masking, 300-character cap |
| `history` | `runs-*.tsv`, `jobs.tsv`, `runner.tsv` writers; the single status goroutine |
| `sched` | scheduler: offsets, single-flight, cap, window rule, missed runs, registry reload |
| `logx` | UTC-stamped one-line logger |
| `notify` | Discord webhook notifier and alerts (rate limit, masking, no URL in logs) |
| `queue` | Redis queue consumer: drain, promote, recover, take; completion writes; parking; redis_state |

Run the unit tests with `platform/jobs/test_go.sh` (pinned toolchain, `-race`).

## Scheduling behaviour

- Cron is evaluated in the zone of `BACKUP_WINDOW_TZ` from `window.env`. Each job fires at its cron minute
  plus `fnv1a32("<app>/<job>") mod 60` seconds. A changed zone recomputes every `next_due` at the next 30s tick.
- At most one run per (app, job) at a time, shared by scheduled and queued runs: the second is
  `skipped_overlap` (scheduled) or waits (queued, Step 7).
- At most `3` runs in flight platform-wide (`MaxConcurrent`). A scheduled fire waits up to 60s for a slot,
  then is `skipped_cap`.
- The timeout is enforced with the injected clock; a timed-out request is cancelled and recorded as `timeout`.
- A run cut off by the runner's own shutdown (`SIGTERM`) is recorded as `interrupted`, not `failed`, and sends no
  alert, so a deploy does not page. The next fire is the retry.
- Redirects are never followed (the bearer token is never re-sent); a 3xx is `permanent`. A status outside
  the outcome table is `permanent`. A transport error (refused connection, DNS failure, reset) is
  `retryable`; for a scheduled job both end as `failed` and the next fire is the retry.

## Backup window

`window.env` is re-read by name on every window decision and on the 30s reload tick (never cached, so a
replaced file with a new inode is seen). A scheduled fire is `skipped_window` when it is inside
`[START, END)` or when `fire + timeout` would pass `START` the same day (a run ending exactly at `START` is
allowed). A refused `catch_up: true` job runs once at `END` plus its offset; that deferral is saved in
`schedule.tsv`, so it survives a restart. A missing, unreadable or malformed file refuses every run
(`refused_config`), sets `runner.tsv` `window_state=invalid`, shows `window_refused` on every `jobs.tsv` row
and sends one alert per change of state. The refusal fails closed and is not deferred, even for `catch_up`:
a `catch_up` run refused because `window.env` is invalid is lost, and the next fire is the retry.

The rule is time-based only. It never checks whether a backup is really running, so a `Persistent=true`
catch-up nightly backup that starts outside `[START, END)` can overlap with jobs. This is accepted.

Queued items (Step 7) are taken in enqueue order per app; a head that is in flight or held by the window rule
blocks that app's later items until it clears. This head-of-line blocking is intentional, to keep order, and
never blocks other apps.

## Missed runs and clock jumps

`jobs-state/schedule.tsv` holds `app<TAB>job<TAB>last_fired` (RFC3339 UTC, temp + rename). While a refused
`catch_up` run is waiting for the window to end, its row gains two more columns,
`app<TAB>job<TAB>last_fired<TAB>deferred_until<TAB>deferred_for` (RFC3339 UTC: when it runs, and the fire
time it stands for), and goes back to three columns once it has run. The loader accepts 3 or 5 columns; any
other row is logged as `schedule_state=bad_row` and ignored. If `window.env` is invalid at start, the first
valid read only sets the schedule zone: `last_fired` is kept, so runs missed meanwhile are still handled. A
later change of zone restarts the schedule from the current time. A backward clock jump is not detected; the
next fire time stays where it was. On start, and
after a wall-clock jump of more than 2 minutes (seen between two 30s ticks), every job whose previous due
time is after `last_fired` runs once with `trigger=catch_up` (only `catch_up: true`, still subject to the
window and the cap) or is recorded as `skipped_missed`. One record per job, however many fires were missed.
The walk over missed fires is bounded (5000 per scan); if a dense schedule after a long outage exceeds that, the
last-fired marker moves to the current time, so later scans do not repeat the same `skipped_missed` records.
A job more than 2 minutes late is treated the same way. A missing `schedule.tsv` is a first start: nothing is
caught up and the log says `state schedule_state=absent`; a job new to the file is treated the same.

## Files the status page reads

All under `/var/lib/platform/jobs-status/`, formats as in the plan's "Shared contracts":

- `runs-YYYY-MM-DD.tsv` (UTC dates, newest 30 kept): `run_id app job trigger scheduled_for started_at
  ended_at duration_ms result http_status attempt error`. One `write(2)` per line, under 4 KiB, `error`
  masked and at most 300 characters with tabs and newlines turned into spaces. The `error` column carries
  app-controlled text, so any consumer (the status page) MUST HTML-escape it.
- `jobs.tsv`: one row per declared job, rewritten atomically after every run and reload. An app whose
  `app.yaml` is invalid gets one placeholder row (`job` is `-`, `state=disabled_invalid_config`). So does a registry
  directory whose name is in `platform/registry/reserved-names.txt` (the runner embeds a copy, kept equal by a test),
  so the deploy-time validator is not the only gate.
- `runner.tsv`: one line, rewritten by a single status goroutine with a 15s heartbeat that does not depend
  on Redis, the window or run activity.

## Queue consumer: parking, OOM and partial writes

- **Parked app.** A deterministic Redis error on an app's keys (for example `WRONGTYPE`) parks that app: one
  alert, then a probe every 60s; the skip log is rate-limited to once per 60s. Parking is alert-only: it is not in
  `runner.tsv` or `jobs.tsv` (`redis_state` stays `ok`; it is `down` or `invalid` only for connection loss or an
  unreadable store). To fix it, inspect the key as admin (`TYPE <app>:jobs:<queue|processing|dead|delayed>`),
  restore the expected type (a list; the delayed key is a sorted set) and the app resumes at the next probe.
- **OOM.** Redis rejecting writes with `OOM` is alert-only too: the item stays in `processing`, writes retry with
  backoff (1s doubling to 30s), and one more alert is sent when a write is accepted again.
- **Partial EXEC.** A completion write is one `MULTI/EXEC`; if one command inside fails at run time the others
  still apply. The consumer inspects every reply and logs `partial EXEC applied ... failed ...` with the item's id, job name and byte length (never the payload, which may hold user data; the item stays
  in `<app>:jobs:processing` or `:dead`). Park log lines carry the same summary.
- **Real-Redis check.** `platform/jobs/test_jobs_live.sh` runs the consumer against the pinned Redis image with the
  real runner ACL; it needs docker (skips loudly without it, fails under `REQUIRE_DOCKER=1`). `PJLIVE_SKIP=1`
  opts out with a loud skip, and is still a failure under `REQUIRE_DOCKER=1`. A run passes only if at least 20
  `TestLive/` subtests passed (fewer when `PJLIVE_RUN` filters).

## Discord alerts

The webhook comes from `jobs.env`, a file with exactly one line `DISCORD_WEBHOOK=https://...` (comments and blank
lines are allowed; the runner refuses to start on a duplicate or extra key, a non-https URL or a quoted value). The
URL is masked in every alert and log line. Run-failure alerts (`failed`, `timeout`, `dead_lettered`) for the same
app, job and result collapse to one per 15 minutes, with a "N more since HH:MMZ" count on the next one. State
alerts (Redis down or ok, app parked or served again, OOM) are never collapsed: each change sends one.

## Logging

One line per event on stdout, each starting with a UTC RFC3339 timestamp. Per run:
`run start app= job= trigger= run_id=` and `run end app= job= trigger= run_id= result= http= dur_ms=`; a skip
logs `run skip ... result= why=` with the state that decided it. The secret and the response body are never
logged.
