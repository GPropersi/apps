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
