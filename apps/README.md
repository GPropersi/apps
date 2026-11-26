# apps/

One directory per app: `apps/<name>/`. Each app carries its own `app.yaml`, `Dockerfile` and `test_*.sh`.

The `app.yaml` schema (every field, the allowed values and the reserved names) is documented in
[`platform/registry/README.md`](../platform/registry/README.md), with a valid example in
`platform/registry/app.yaml.example`. `make lint` validates every tracked `apps/*/app.yaml`.

## The per-app contract

Tests are a requirement of being an app. `make lint` (`platform/lint/check-apps.sh`) refuses an app whose tracked
`app.yaml` lacks any of:

- **Tests:** at least one tracked `apps/<name>/test_*.sh`. A test file exits non-zero on failure, needs no platform
  host, runs from the repo root, wraps the app's native runner, and sets up its own exact-pinned toolchain. Docker tests
  honour `REQUIRE_DOCKER`. An app test that starts real containers must carry `# test-class: docker` within its first
  10 lines, use per-run names (app tests run side by side with platform tests), and open with the standard skip
  preamble (`docker info ... || skip ...`, as the platform live tests do): `make lint`
  (`platform/lint/check-test-classes.sh`) detects live tests through that preamble, so a live test written without it
  escapes detection and runs uncapped.
- **A `Dockerfile`** with every `FROM` pinned as `@sha256:<64 hex>` (a `FROM` of an earlier stage alias, or `scratch`, is
  allowed).
- **A numeric non-zero runtime user:** the last `USER` of the final stage is a literal uid such as `USER 1000` or
  `USER 1000:1000`, never a name, `root`, `0` or a `$`-expanded value. Lint checks this at PR time; the deploy `inspect`
  step checks the built image and is the authority.

## Declared volumes

An app that needs files to survive restarts and redeploys declares them in `app.yaml` (`volumes`, 1 to 4 entries, each
a `name` and a `path` under `/data`; see the registry README). Deploy creates the Docker volume `app_<app>_<name>`
(labelled `platform.app=<app>` and `platform.volume=<name>`) and mounts it read-write at `path`; the container root
stays read-only. A volume name that already exists with another app's label (or none) fails the deploy before any
container change.

Install order: before the first deploy of an app that declares volumes or routes, run `make host-deploy-user`, then
`make host-jobs`, then `make host-ingress` (each with `ARGS="install"`), in that order. An older jobs-runner binary
treats `volumes` as unknown and may drop job scheduling, and an older ingress has no file routes.

- **Ownership contract:** docker copies the image's directory ownership into an empty named volume on first mount, so
  the image must contain each `path` as a directory owned by its numeric `USER` (for example
  `RUN mkdir -p /data/files && chown 1000:1000 /data/files`). Deploy cannot chown (it has no root); a path missing from
  the image is created root-owned and the app cannot write it.
- **First-deploy failures:** volumes created for a first deploy whose health check fails are left in place (empty)
  and removed only by `make host-app-rm ... --stop`.
- **One writer:** deploy stops the old container before the new one starts, so two containers never mount a volume
  together. A rollback runs the older image against data the newer one may have changed, so keep on-disk formats
  backward compatible.
- **Removal:** `rm-db --stop` deletes every volume labelled `platform.app=<app>` (listing them first); without
  `--stop` it refuses while any exists, naming them.

## Starting a new app

`make app-new NAME=<name> PURPOSE="<one line>"` scaffolds `apps/<name>/` from `templates/go-react/` (see
[`templates/README.md`](../templates/README.md)); it is offline and leaves `apps/` unchanged when it refuses. An app
declaring `template: go-react` carries a byte-identical copy of the template's `internal/platform/` (a lint enforces
it) and uses `access` absent or `family` only.

An app adds no `Push gate` row and no CI file: `make test` discovers `apps/<name>/test_*.sh` on disk, and the catch-all
row of the `Push gate` runs it.

## Notifications (4irl-notifs)

An app that sends phone, Discord or webhook notifications through 4irl-notifs opts in with `notifs: true` in its
`app.yaml` (see the registry README). Apps without it never get a key. The key reaches the app in four host files under
`/run/platform/secrets/` (`notifs-key`, `notifs-access-client-id`, `notifs-access-client-secret`, `notifs-base-url`);
read them on every call, because the key rotates on each exchange (the previous one stays valid for 24 hours).

The key is fetched by a separate, manual-only workflow, `.github/workflows/notifs-exchange.yml`. It never runs on a
merge or after a deploy, so a failed exchange can never break or roll back a deploy. It is a standalone file because
4irl-notifs binds this one workflow as a registrar: the binding is exact on the file, and it covers every app in the
monorepo (an app's notifs id is `apps_<name>`, with `-` written as `_`).

- **Inputs:** `app` (one app name; empty means every app with `notifs: true`) and `dry-run`. An explicit `app` without
  `notifs: true` fails instead of doing nothing.
- **What it does, per app:** exchanges this run's GitHub OIDC token for a key, joins the tailnet exactly like the deploy
  job and pipes the key set to the host's restricted `notifs-key <app>` command, then compares the sha256 the host prints
  with its own. Only the hash is ever logged. The job runs in the `production` environment (the same one the deploy uses)
  and only from `main`.
- **Run it** after the first deploy of an app that sets `notifs: true` (the host refuses an app that has never
  deployed), and again by hand within 24 hours whenever a run exchanged a key but failed to write it.
- **One-time operator steps:** set the repository variable `NOTIFS_DELIVERY_URL` and the secrets
  `NOTIFS_ACCESS_CLIENT_ID` / `NOTIFS_ACCESS_CLIENT_SECRET` (the Access service token for delivery-api); run the
  workflow once with `dry-run` to print the OIDC claims (`workflow_ref`, `ref`, `environment`); approve that identity as a
  registrar in the 4irl-notifs admin UI; then run it for real. A dry run still exchanges, which rotates the app's key, so
  follow it with a real run within 24 hours. `NOTIFS_DELIVERY_URL` must be a repository *variable*: a secret of that
  name is invisible to `vars.` and the workflow sees an empty URL.
- **Run it right after the first deploy:** until the key is written, the app's daily scan fails once a day with one
  alert each time, and it enqueues nothing.
- **Expected first failure:** the first run after merge fails with 401 or 403 until the registrar identity is approved.
  A 302 from Cloudflare means Access rejected the service token (it is missing from the `notifs-delivery` policy, or
  the ID and secret do not match). A 401 or 403 later means the identity or the Access service token no longer
  matches what was approved, never a deploy problem; a write failure (the host rejected the key, or the hashes
  differ) means rerun it within 24 hours.
- **Host prerequisite:** re-run `make host-deploy-user` and `make host-data` (the same ARGS as the first install) since the
  `notifs-key` command shipped, or the host answers with an unknown-command error.
- **The `app` input:** empty means every opted-in app, and `all` also means every app; an explicit app must have
  `notifs: true`.

## Rules every app follows

- **Never answer 502, 503 or 504.** The edge replaces those bodies with the platform down page, so a client must not
  parse them as JSON and the app uses 4xx or 500 for its own errors.
- **Migrations stay backward-compatible.** A rollback restores the old container but never reverts the schema, so each
  migration must work with the previous version of the app (add first, remove or rename in a later release).
