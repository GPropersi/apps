# platform/backup

Nightly backup of the shared data layer (Postgres, Redis, the secrets root and the two admin password files) to a
restic repository in a Cloudflare R2 bucket. `backup.sh` runs as root from a systemd oneshot on the app host (or by
hand: `backup.sh nightly|manual`). Tracked in issue #13.

What is here:

- **`backup.sh`**: the run framework (logging, Discord notify, last-run state file, backup window, total deadline) and
  the phases, in order: `env`, `lock`, `preflight`, `pg-list`, `pg-globals`, `pg-db:<db>` (one dump per database),
  `redis` (BGSAVE and copy), `restic-backup`, `restic-forget`, `restic-check`, `volumes` (warn-only inventory of
  Docker volumes nothing backs up).
- **Snapshots**: one restic snapshot per run, host `platform`, tags `platform` and the run mode (`nightly` or
  `manual`), holding the Postgres dumps and globals, the Redis files, the secrets root and the two admin password
  files. Retention: `forget --prune` keeps 7 daily, 4 weekly and 6 monthly snapshots; it is skipped (and the run
  fails, naming the reason) unless the repository lists the snapshot just created and at least one more than before.
- **`restore.sh`**: run as root, modes `list`, `app APP --into DB`, `secrets APP`, `host-files` and
  `full --confirm-destroy`; steps and refusals are in [`RUNBOOK.md`](RUNBOOK.md).
- **Units**: `platform-backup.service` (oneshot) and `platform-backup.timer`, firing at 03:35 inside the window. `window.env` holds the window.
- **Installer**: `../host/install-backup.sh` (`make host-backup`), which embeds all of the above.
- **Tests**: `test_backup.sh` and `test_restore.sh` (offline, stubs for `restic`, `docker` and `curl`) and
  `test_backup_live.sh` (with `test_backup_live_skip.sh`), the live restic and R2 round trip, which skips without
  its credentials.

## Credentials: `/etc/platform/backup.env`

Written by hand on the host, root-owned, mode 0600 (never by the installer, never committed). Literal `KEY=VALUE`
lines, all six required, no quotes:

```
RESTIC_REPOSITORY=s3:https://<account-id>.<r2-endpoint-host>/<bucket>
RESTIC_PASSWORD=<restic repository password>
AWS_ACCESS_KEY_ID=<r2 access key id>
AWS_SECRET_ACCESS_KEY=<r2 secret access key>
AWS_DEFAULT_REGION=auto
DISCORD_WEBHOOK=<discord webhook url>
```

The reader never `source`s the file. Each line splits at the first `=`; the value is everything after it (no quote,
backslash, whitespace or comment processing). Blank lines and lines starting with `#` are skipped. A symlink, a file
not owned by `0:0` or not mode 0600, a CR, a line without `=`, an unknown or duplicate key or a value that starts with
a quote is refused with exit 2. A missing key exits 2 and the message names every missing key. The webhook is never
called for an `env` failure (it may be the missing key). Secret values are replaced with `***` in every log line,
error text and Discord message.

Test overrides (`PLATFORM_BACKUP_*` and `PLATFORM_RESTORE_*`, each defaults to the production path) are documented in
the header of `backup.sh` and are honoured only with `PLATFORM_BACKUP_TESTING=1`; without it they are ignored and
named in a warning. A non-production backup root must hold a `.platform-backup-root` file before `staging/` is wiped.

## `last-run.tsv` (for the status page)

`/var/lib/platform/backup-status/last-run.tsv` (dir root 0755, file 0644), one line, written atomically (temp file
then `mv`) from the exit trap so a crash still records a failure:

```
start_utc<TAB>end_utc<TAB>result<TAB>snapshot<TAB>failed_phase
```

`result` is `ok` or `failed`; `snapshot` and `failed_phase` are `-` when empty; times are ISO-8601 `Z`;
`failed_phase` is a phase label (including `env` and `lock`).

## `window.env` (for the jobs runner)

`BACKUP_WINDOW_START`, `BACKUP_WINDOW_END` and `BACKUP_WINDOW_TZ`, shell-sourceable, no other keys, installed as
`/opt/platform/backup/window.env`. The window is `[START, END)` local time in the given zone. A `nightly` run that
starts outside it, or starts inside and ends after `END`, still succeeds and adds a warning to its Discord message
(`started outside backup window`, `overran backup window`); a `manual` run adds neither. A `Persistent=true` catch-up
run can start at any hour, so anything that reads the window must tolerate that.

## Run rules

- One run at a time: `flock -n` on `/run/platform-backup.lock` (the `lock` phase); a held lock fails the run with
  `failed_phase=lock`.
- Total deadline 4200s from start, checked before each phase; every phase timeout is clamped to the time left. The
  `notify` call (30s) and the state write are exempt, so a late failure is still reported.
- Logs go to journald and to `/var/log/platform-backup/<YYYY-MM-DD>.log` (30 days, at least 30 files kept).
