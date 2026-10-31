# platform/

Host and platform scripts: the `deploy` entry point, jobs runner, backups, status page and host
install scripts. `platform/ingress/` is the tunnel, Traefik and down-page stack (see its README).
`platform/data/` is the shared Postgres and Redis stack, installed by `platform/host/install-data.sh`
(see its README). `platform/registry/` holds the app registry schema and validator.
`platform/backup/` is the nightly backup to R2 and the restore tool, installed by
`platform/host/install-backup.sh` (`make host-backup`, `make host-restore`; see its README and RUNBOOK).
`platform/jobs/` is the shared jobs runner (scheduled and queued jobs, Go), built on the host and installed by
`platform/host/install-jobs.sh` (`make host-jobs`; see its README).
`platform/lint/` holds this repo's own checks (public-repo hygiene).
