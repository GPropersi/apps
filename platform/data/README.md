# Shared data stack

One Postgres and one Redis for every app, run as the Compose project `platform-data` on the `platform` network
(installed to `/opt/platform/data` by `install-data.sh`). Nothing is published: apps reach the services by their
Compose service names `postgres` and `redis`.

## Layout

| File | Role |
|---|---|
| `compose.yaml` | The two services, hardened like the ingress stack (pinned image and digest, `cap_drop: ALL`, `no-new-privileges`, read-only root, memory limit, no published ports). Fixed container names `platform-data-postgres` and `platform-data-redis` (one data stack per host, by design). |
| `pg_hba.conf` | Mounted read-only. One `local all postgres peer` line (used by `docker exec` as the postgres uid, so `new-db` and `verify` need no password) and `scram-sha-256` `host` lines on `samenet`. No `trust`. |
| `redis-entrypoint.sh` | Mounted read-only as the Redis entrypoint. Builds `users.acl` from the admin secret file at first start (atomic write), then execs `redis-server`. |
| `new-db.sh` | The `platform new-db <app>` helper, installed to `/opt/platform/data/new-db.sh` (`root:root 0755`) and run by the dispatcher as `deploy`. Gives one app its own Postgres role and database and its own Redis user, writing the credentials to the secret files below. See "Provisioning an app". |
| `test_data_stack.sh`, `test_redis_entrypoint.sh`, `test_new_db.sh` | Offline tests (`make test`). |

Data lives in the named volumes `platform-data-postgres` (mounted at `/var/lib/postgresql`, the data path of the
pinned major 18; majors up to 17 use `/var/lib/postgresql/data`) and `platform-data-redis` (`/data`), so later backup
steps can find them by name. `pg_dump` must match the pinned Postgres major.

## Secrets

Every secret is a mounted file; no password is in any container's environment or command line (Traefik can read every
container's environment until master step 11).

- Admin secrets are user-created, never written or printed by the installer: `/etc/platform/postgres-admin.password`
  and `/etc/platform/redis-admin.password`, `root:64322 0640`, a single line. The containers read them through
  `group_add: ["64322"]`.
- Redis cannot read a password from a file, so the entrypoint hashes the admin password (one trailing newline
  stripped) into `users.acl` with `user default off`, an `admin` user, and a `nopass` `health` user limited to `+ping`.
  The Redis healthcheck authenticates as `health` with the fixed non-secret placeholder `placeholder` (a nopass user
  accepts any password; without a password argument `redis-cli` would not send AUTH). That literal is the single
  exception to "no password in argv".
- Postgres tuning keeps `log_statement=none` and `log_min_error_statement=panic`, so a failing
  `CREATE ROLE ... PASSWORD` never writes its statement, and so the password, into the container log.

## Memory budget (4 GB host)

| Service | `mem_limit` | Main setting |
|---|---|---|
| postgres | 512m | `shared_buffers` 128MB, `max_connections` 60, `shm_size` 128m |
| redis | 192m | `maxmemory` 96mb (half the cap: the AOF rewrite buffer and copy-on-write pages are not counted by `maxmemory`) |

Redis memory is shared by all apps with no per-app quota. With `maxmemory-policy noeviction` (queued jobs must never
be evicted) a full Redis rejects every app's writes. This is not prevented, only monitored: `install-data.sh verify`
prints a WARN at about 80% of `maxmemory`. Redis isolation is key and command scoped, not resource scoped.

Host note: Redis wants `vm.overcommit_memory=1` for background saves under memory pressure. `verify` checks it and
prints the instruction; this stack never sets it.

## App Redis ACL

Each app gets a Redis user limited to its own keys (`~<app>:*`) with dangerous commands removed. `SCAN`,
`RANDOMKEY` and `DBSIZE` are denied to app users so the key names of other apps cannot be enumerated. An app whose
client library scans its own keyspace needs a per-app exception, added later.

## Provisioning an app

`platform new-db <app>` (over the `deploy` identity) is idempotent, never rotates a password and prints only the
secret file paths. The Postgres role and database are the app name with `-` replaced by `_` (connection limit 3,
`CONNECT` revoked from `PUBLIC` on the database, `PUBLIC` also revoked on `postgres` and `template1`, `public`
schema revoked from `PUBLIC`); the Redis user is the app name with the key prefix `<app>:`. Per app it writes
`/var/lib/platform/secrets/<app>/db-password` and `redis-password` (40 characters `[A-Za-z0-9]`, `0440`, in a `2750`
directory; the group comes from the setgid secrets root, so no `chgrp` runs).

- A per-app `flock` serializes concurrent calls. Both containers must be healthy before anything is written.
- A read-only preflight classifies both stores against both secret files. An object that exists while its secret
  file is missing exits 1 before any write (nothing is modified in either store): restore the file from a backup, or
  drop the role and database (or `ACL DELUSER` the Redis user) by hand if the app holds no data.
- A secret file whose object is missing is used as is: the object is created with that password.
- Every idempotent statement is re-applied on each run, so a drifted connection limit or Redis rule is repaired.
- Names are checked before any docker call: the app-name pattern, the installed `reserved-names.txt` (a missing list
  fails closed), and the Postgres identifier rule (no `pg_` prefix; not `postgres`, `template0`, `template1`, `public`).
- Each phase logs its start, end, rc and duration to stderr and to `logger -t platform`; error text is masked.

## Connection contract

A platform-wide, non-secret `connection.env` carries `PLATFORM_PG_HOST`, `PLATFORM_PG_PORT`, `PLATFORM_REDIS_HOST` and
`PLATFORM_REDIS_PORT`, so inserting PgBouncer at about 15 apps changes only the host and port. Its host values are the
service names `postgres` and `redis` on the `platform` network.

PgBouncer-safe client rules: no session `SET`, no advisory session locks, no `LISTEN`/`NOTIFY`, no named prepared
statements across transactions.

App environment names:

```
DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD_FILE
REDIS_HOST REDIS_PORT REDIS_USER REDIS_PASSWORD_FILE REDIS_KEY_PREFIX
```

Secrets are files, never values. The per-app secrets directory is `/var/lib/platform/secrets/<app>` (files
`db-password` and `redis-password`), mounted read-only into the app container with `group_add: ["64323"]`.
