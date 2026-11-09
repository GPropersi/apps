# CLAUDE.md — apps

Public monorepo for the self-hosted app platform: `platform/` (host and platform scripts), `apps/<name>/`
(one directory per app), `templates/` (app starting points), `.github/workflows/` (CI, build and deploy).
Design and phases live in the stronghold: `~/code/plans/stronghold/open/app-hosting-platform/`.

## Public repo rules (read before every commit)

- **Public repo: no secrets, tokens, keys, personal data, IP addresses, tailnet names or ssh-scheme URLs, ever.**
  Credentials live in host-side files and repo secrets. `make lint` enforces this; fix the leak, do not
  allowlist it, unless the value is genuinely public.
- Workflows never use `pull_request_target`; deploy jobs run only on `push` or `workflow_dispatch` from `main`: every job
  with `environment:` carries a job-level `if:` testing `github.ref == 'refs/heads/main'` (never
  `event_name == 'pull_request'`, no `||`), so it never runs for fork PRs; `make lint` enforces it, with 40-hex action pins.
- Deploy configuration (names only; values live in GitHub settings and never in this repo): environment `production`
  (deployment branches: `main` only, no required reviewer); its variable `PLATFORM_DEPLOY_HOST`; the repository variable
  `PLATFORM_BUILD_ARCH`; the environment secrets `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` (the Tailscale identity
  `tag:ci`, which reaches the host only as the restricted `deploy` login). Only the `deploy` and `rollback` jobs see them.
- Deploy rules: a merge to `main` tests only the changed app (`make test-app APP=<app>`), builds it, and deploys it with
  health-checked replacement; the full suite runs beside it and never blocks a deploy. GHCR packages stay private: the
  deploy job hands the host its own short-lived `GITHUB_TOKEN` on stdin. A deploy never goes backwards, rollback is the
  manual `app-rollback.yml`, and app removal is admin-only (`make host-app-rm`), never a CI path. Moving servers:
  `platform/backup/RUNBOOK.md` "Moving to a new server".
- Every change reaches `main` through a PR with the `ci` check green; reviewer `GPropersi`.
- Pin every dependency, image and action to an exact version (actions to a full commit SHA).
- Tool pins: shellcheck is pinned in `platform/lint/SHELLCHECK_VERSION`. Go is forced by
  `GOTOOLCHAIN=go<GO_VERSION>` from `platform/jobs/GO_VERSION` (exported by `check-go.sh`, `test_go.sh` and
  every script that runs go), so there is no machine-wide Go pin to maintain and the shared system Go is never
  modified. The `go.mod` `toolchain` line must equal it (`make lint` checks); the `go` line is the language
  version `1.26` because Go drops a `toolchain` line that equals the `go` line. Bump `GO_VERSION`, the
  `toolchain` line and the Dockerfile builder digest together.

## Claude Config

<!-- Consumed by central generic skills. Stable keys — do not rename. -->

- **Repo slug:** `GPropersi/apps`
- **Default branch:** `main`
- **Plans store (central):** `~/code/plans/apps/{open,completed,research}/<topic>/`
- **Plans bucket:** `apps`
- **Push gate:** (suites a push must pass; first matching row wins per changed path, all matched suites run sequentially; an app adds no row, its `apps/<name>/test_*.sh` runs under the catch-all)
  | Paths (space-separated globs)               | Command                                             |
  | ------------------------------------------- | --------------------------------------------------- |
  | `README.md **/README.md docs/** .claude/**` | na docs and skill text only, no code or build input |
  | `**`                                        | `make lint && make test-changed`                    |
- **Bot identity:** `gpropersi-claude[bot]` `141576524+gpropersi-claude[bot]@users.noreply.github.com`
- **Bot push script:** `~/code/.claude/scripts/gh-app-push.sh` (central, repo-agnostic; derives the repo from `origin`, pushes as the shared bot)
- **Token generator:** `~/code/.claude/scripts/generate-gh-token.sh` (tracked in the stronghold; the shared `gpropersi-claude` App, installation resolved from the repo owner)
- **Container runtime:** docker
- **App URL (Playwright MCP):** n/a
- **Test login:** n/a
- **Commands:**
  | Purpose | Command |
  |---|---|
  | Help | `make help` |
  | Lint (public-repo hygiene + embed drift + app.yaml registry validation + per-app contract + shellcheck) | `make lint` |
  | Tests (every `platform/**/test_*.sh`, `apps/<name>/test_*.sh` and `templates/<name>/test_*.sh`; knobs `TEST_JOBS`, `TEST_DOCKER_JOBS`, `TEST_VERBOSE`, `TEST_FILE_TIMEOUT`; `TEST_JOBS` and `TEST_DOCKER_JOBS` default to `auto`: sized from CPUs and memory, a hostq job takes `nproc / HOSTQ_SLOTS` CPUs (`HOSTQ_SLOTS` defaults to 2, mirroring hostq's configured slot count; update the default in `platform/test/run.sh` if hostq's changes), new files are held while memory is low, and the first output line names the decision) | `make test` |
  | Tests the change since `BASE` needs, per `platform/test/areas.map` (default `BASE=origin/main`; same `TEST_*` knobs as `make test`; a `.github/**`-only change runs just the lint and ci tests, and the selected files' images and Go toolchain are prewarmed once before the run) | `make test-changed` |
  | One app's tests | `make test-app APP=<name>` |
  | Regenerate embedded installer payloads | `make embed` |
  | List registered apps (registry only, offline) | `make app-ls` |
  | Scaffold a new app from a template, offline: no network, ssh or `platform new-db`; refusals leave `apps/` unchanged | `make app-new NAME=<name> PURPOSE="<one line>" [TEMPLATE=go-react] [OWNER=gpropersi]` |
  | Regenerate sqlc Go code with the pinned generator image (`TEMPLATE=<name>` or `APP=<name>`, exactly one; needs docker) | `make app-sqlc TEMPLATE=go-react` |
  | Live host: registered apps plus live state; needs the passwordless sudo the other `host-*` targets use (you run it; `HOST` required) | `make host-app-ls HOST=<alias>` |
  | Live host: deploy identity installer (you run it; `HOST` required) | `make host-deploy-user HOST=<alias> ARGS="install --pubkey-file PATH"` |
  | Live host: claude identity installer (you run it; `HOST` required) | `make host-claude-access HOST=<alias> ARGS="install --pubkey-file PATH"` |
  | Live host: ingress stack installer (you run it; `HOST` required) | `make host-ingress HOST=<alias> ARGS="install"` |
  | Live host: shared Postgres and Redis installer (you run it; `HOST` required) | `make host-data HOST=<alias> ARGS="install"` |
  | Live host: jobs runner installer, incl. the explicit `testapp-up` / `testapp-down` (you run it; `HOST` required) | `make host-jobs HOST=<alias> ARGS="install"` |
  | Live host: nightly backup installer and checks, incl. `run-now` and `init-repo` (you run it; `HOST` required) | `make host-backup HOST=<alias> ARGS="install"` |
  | Live host: restore from the backup, runs `restore.sh` as root over ssh (you run it; `HOST` required) | `make host-restore HOST=<alias> ARGS="list"` |
  | Live host: DESTRUCTIVE admin-only app removal, runs `rm-db.sh` as root over ssh; remove `apps/<name>/` by PR first (you run it; `HOST` required) | `make host-app-rm HOST=<alias> ARGS="<app> --confirm <app> [--stop]"` |
  | Live host: public Access-gate check, run from here (`HOST` required; domain via `PLATFORM_DOMAIN` or `--domain`) | `make host-verify-ingress HOST=<alias> ARGS="--domain D"` |
  | Live host: read-only egress check (`HOST` required) | `make host-verify-egress HOST=<alias> ARGS="--probe"` |
- **GitHub project board:** n/a
- **Issue labels:** n/a
- **PR reviewer:** `GPropersi`
- **Worktree policy:** `build-only`
- **Worktree allowed targets:** `help, lint, test, test-changed, test-app, embed, app-ls, app-new, app-sqlc`
- **Worktree link:** `n/a`
- **Worktree setup:** `n/a`
- **Worktree teardown:** `n/a`
- **Worktree ports:** `n/a`
- **Worktree guarded targets:** `n/a`
