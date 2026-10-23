# platform/backup

Nightly backup of the shared data layer (Postgres, Redis, the secrets root and the two admin password files) to a
restic repository in a Cloudflare R2 bucket. `backup.sh` runs as root from a systemd oneshot on the app host (or by
hand: `backup.sh nightly|manual`). Plan: `backups-r2` (Steps 1 to 5 build the runner, the phases, `restore.sh`, the
unit and timer, and the installer).

This directory so far holds the **run framework** (`backup.sh`): the `env` and `lock` phases, logging, the Discord
notify, the last-run state file, the backup window and the total deadline. Real phases are added to `PHASES` by the
next step. Tests: `test_backup.sh` (offline, stubs for `restic`, `docker` and `curl`).

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

Test overrides (`PLATFORM_BACKUP_*`, each defaults to the production path) are documented in the header of
`backup.sh`.

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
