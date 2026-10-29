# Backup and restore runbook

How the nightly backup is set up, and how to bring data back. `restore.sh` is the restore tool: it is run by hand as
root (`sudo /opt/platform/backup/restore.sh ...`) and shares one lock with `backup.sh`, so a restore waits (fails with
exit 1) while a backup runs.

## 1. R2 setup checklist

1. In the Cloudflare dashboard create **one** R2 bucket for backups.
2. Create an **Object Read & Write** API token scoped to that bucket only (no account-wide access).
3. Note the bucket's S3 endpoint, the token's access key id and secret, and create a Discord webhook for the alerts.
4. Write `/etc/platform/backup.env` yourself (the installer never writes it). Values are literal: write `KEY=value`
   with **no quotes** (the reader refuses a leading quote, a carriage return, an unknown key and a duplicate key):

   ```sh
   sudo install -m 0600 -o root -g root /dev/null /etc/platform/backup.env
   sudoedit /etc/platform/backup.env
   ```

   ```
   RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
   RESTIC_PASSWORD=<long random restic password>
   AWS_ACCESS_KEY_ID=<token access key id>
   AWS_SECRET_ACCESS_KEY=<token secret>
   AWS_DEFAULT_REGION=auto
   DISCORD_WEBHOOK=<webhook url>
   ```

5. Initialise the repository once (an explicit installer mode, never automatic): `make host-backup HOST=<alias>
   ARGS="init-repo"`.

**Store the restic password offsite in your password manager.** Without it the backups cannot be restored, and the
copy in `backup.env` is lost together with the host.

## 2. Look at what exists

```sh
sudo /opt/platform/backup/restore.sh list
```

Prints the snapshots of host `platform`. Every restore takes `--snapshot <id>` (a hex id from the list) or defaults to
`latest`. `host-files` and `full` log the id and time they resolved before they change anything.

## 3. Restore one app's database (single-app recovery)

The restore goes into a **new** database, owned by the app's role, next to the live one. It never overwrites.

1. Restore into a new name. The database and role are the app name with `-` replaced by `_`, and the new name must stay
   within 31 characters, so use a short suffix such as `_r` for long names:

   ```sh
   sudo /opt/platform/backup/restore.sh app <app> --into <db>_restore
   ```

   It prints the row count per table.
2. Check the restored data (for example `sudo docker exec -i platform-data-postgres psql -U postgres -d <db>_restore`).
3. To swap it in: stop the app, then rename both databases in one go (connections to either must be closed first):

   ```sql
   ALTER DATABASE "<db>" RENAME TO "<db>_old";
   ALTER DATABASE "<db>_restore" RENAME TO "<db>";
   ```

   Start the app, and drop `<db>_old` once you are satisfied.

If an app's password files were lost, bring them back with `sudo /opt/platform/backup/restore.sh secrets <app>`
(it refuses when `<secrets root>/<app>/` or `<job-secrets root>/<app>/` already exists; owner becomes the current
`deploy` uid, with gid 64323 for the password files and gid 64324 for `job-secrets/<app>/jobs-secret`; dirs 2750, files
0440). A snapshot of an app made before job secrets existed holds no `job-secrets/<app>/`: the command says so and
restores the password files alone; run `platform new-db` to create the job secret. The two trees are validated and
staged before either is moved; if a move still fails midway, `secrets/<app>/` may exist without `job-secrets/<app>/`:
move the placed `secrets/<app>/` aside and run the command again.

The runner Redis password (`/etc/platform/jobs-redis.password`, `root:64324 0640`) is in every nightly once the runner
is installed, and `restore.sh full` puts it back. It only works as a pair with `users.acl` (restored from the Redis
copy in the same snapshot): the ACL line carries the hash of that password, so restoring one without the other leaves
the runner failing `WRONGPASS`. Restore both from the same snapshot. `/etc/platform/jobs.env` is intentionally NOT
backed up (it holds the Discord webhook, like `backup.env`): after a restore recreate it per `platform/jobs/README.md`,
then run `host-jobs install`.

## 4. Rebuilt-host order (a whole new machine)

Order matters: the admin passwords must exist before the data stack starts, and the data stack before the restore.

Rollout order: `host-data install` must run before the first `host-backup install` that deploys the `backup.sh` that
backs up the job-secrets root (it creates that root; a nightly with the root missing fails the env phase). The same
holds on a rebuilt host: `install-data install` (step 4) creates the root `full` needs.

1. `install-deploy-user`
2. `install-backup restore-only` (needs only a valid `/etc/platform/backup.env`; installs restic and `restore.sh`, no
   timer, no unit, no data-stack requirement)
3. `restore.sh host-files` (on a host without the two admin password files; it writes each only when absent or
   byte-identical and refuses a differing file)
4. `install-data install`
5. `restore.sh full --confirm-destroy`
6. `install-backup install` (the normal full install, timer last)
7. `install-data verify` and the backup `verify`

`full` refuses unless the stack is fresh: the Postgres cluster must hold only `postgres` and templates, Redis must hold
no key and no ACL user besides `default`, `admin` and `health`, and the admin password files must already match the
snapshot. There is no override. It restores the secrets and job secrets (and the runner password file when the snapshot
holds one; a live copy that differs refuses), loads the Postgres globals, restores every database, re-applies
the `REVOKE CONNECT ... FROM PUBLIC` hardening on `postgres` and `template1`, loads Redis through a one-shot container
(the stack runs `appendonly yes`, which would ignore a bare RDB), and runs `install-data.sh verify` when that script is
present. No installer places `install-data.sh` on the host (it runs from the workstation), so on the Pi that step is
skipped and logged: run `make host-data HOST=<alias> ARGS="verify"` yourself as step 7.

## 5. Wipe procedure (acceptance drill and any in-place recovery)

In this order:

1. **Fence the timer:** `sudo systemctl disable --now platform-backup.timer`. A nightly or `Persistent=` catch-up run
   after the wipe would otherwise write an empty newest snapshot that `latest` then restores, or a failed
   `last-run.tsv`.
2. **Record the snapshot id** to restore (from `restore.sh list` or the preceding `run-now`) and pass
   `--snapshot <id>` to `host-files` and `full`; `full` prints the snapshot it chose.
3. Compose down with `-v`, remove the disposable apps' secret and job-secrets dirs, **and remove the two admin password files**, so
   the drill exercises the rebuilt-host order above.
4. Follow section 4 from step 3 on. The final `install-backup install` re-enables the timer; `verify` FAILs if it was
   left off.
5. Expect a `Persistent=` catch-up run when the timer is re-enabled after a missed 03:35 (the installer never invokes
   the service itself, but systemd may fire it on enable). It takes the shared lock and its snapshot is post-wipe. Wait
   for `systemctl is-active platform-backup.service` to clear before the final `run-now` and `verify`, and never restore
   from that snapshot.

## 6. Troubleshooting

- `restore: missing directory ...`: run `install-backup restore-only`; the restore never creates the state dirs.
- Exit 2 means a refusal or bad input and nothing was changed; exit 1 names the step that failed.
- A one-shot Redis loader left running after a failed run (`platform-data-redis-restore-loader`, named after the
  Redis container): `docker rm -f` it before retrying. The real Redis is left stopped after a failed load: check the
  log (`/var/log/platform-backup/<date>.log`), fix the cause, then wipe the stack again (section 5, step 3) and re-run
  from section 4 step 4: `full` refuses a stack that already holds data, which a half-finished restore does.
- `restore: step 'redis-stop-check' failed`: compose stop selected no running Redis container (check the compose
  file `name:` and `PLATFORM_BACKUP_REDIS_CONTAINER`). Nothing was changed.
- `restore: step 'app-pg-restore' failed` (single-app restore): the new database `<db>_restore` was already created and is
  now half-restored. Drop it before retrying (`sudo docker exec -i platform-data-postgres psql -U postgres -c 'DROP
  DATABASE "<db>_restore"'`), because `app` refuses an `--into` name that already exists.
- `full` validates the whole snapshot (globals, dump names, Redis files, every app secrets and job-secrets directory, the Redis image and
  `/data` mount) before it changes anything, so a refusal (exit 2) at that point needs no wipe: fix the cause (for
  example pick a complete `--snapshot`) and re-run.
- `--keep` leaves the restore directory (`/var/lib/platform/backup/restore/<stamp>`, root only; it holds restored dumps
  and secrets) in place for inspection; delete it when done.
