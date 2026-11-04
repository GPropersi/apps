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
  honour `REQUIRE_DOCKER`.
- **A `Dockerfile`** with every `FROM` pinned as `@sha256:<64 hex>` (a `FROM` of an earlier stage alias, or `scratch`, is
  allowed).
- **A numeric non-zero runtime user:** the last `USER` of the final stage is a literal uid such as `USER 1000` or
  `USER 1000:1000`, never a name, `root`, `0` or a `$`-expanded value. Lint checks this at PR time; the deploy `inspect`
  step checks the built image and is the authority.

An app adds no `Push gate` row and no CI file: `make test` discovers `apps/<name>/test_*.sh` on disk, and the catch-all
row of the `Push gate` runs it.
