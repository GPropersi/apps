# CLAUDE.md — apps

Public monorepo for the self-hosted app platform: `platform/` (host and platform scripts), `apps/<name>/`
(one directory per app), `templates/` (app starting points), `.github/workflows/` (CI, later build and deploy).
Design and phases live in the stronghold: `~/code/plans/stronghold/open/app-hosting-platform/`.

## Public repo rules (read before every commit)

- **Public repo: no secrets, tokens, keys, personal data, IP addresses, tailnet names or ssh-scheme URLs, ever.**
  Credentials live in host-side files and repo secrets. `make lint` enforces this; fix the leak, do not
  allowlist it, unless the value is genuinely public.
- Workflows never use `pull_request_target`; deploy jobs run only on `push` to `main`
  (`if: github.event_name == 'push' && github.ref == 'refs/heads/main'`), never for fork PRs.
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
- **Push gate:** (suites a push must pass; first matching row wins per changed path, all matched suites run sequentially; each app adds its own `apps/<name>/**` row above the catch-all when it lands)
  | Paths (space-separated globs)               | Command                                             |
  | ------------------------------------------- | --------------------------------------------------- |
  | `README.md **/README.md docs/** .claude/**` | na docs and skill text only, no code or build input |
  | `**`                                        | `make lint && make test`                            |
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
  | Lint (public-repo hygiene + embed drift + app.yaml registry validation + shellcheck) | `make lint` |
  | Tests (every `platform/**/test_*.sh`) | `make test` |
  | Regenerate embedded installer payloads | `make embed` |
  | List registered apps (registry only, offline) | `make app-ls` |
  | Live host: registered apps plus live state; needs the passwordless sudo the other `host-*` targets use (you run it; `HOST` required) | `make host-app-ls HOST=<alias>` |
  | Live host: deploy identity installer (you run it; `HOST` required) | `make host-deploy-user HOST=<alias> ARGS="install --pubkey-file PATH"` |
  | Live host: claude identity installer (you run it; `HOST` required) | `make host-claude-access HOST=<alias> ARGS="install --pubkey-file PATH"` |
  | Live host: ingress stack installer (you run it; `HOST` required) | `make host-ingress HOST=<alias> ARGS="install"` |
  | Live host: shared Postgres and Redis installer (you run it; `HOST` required) | `make host-data HOST=<alias> ARGS="install"` |
  | Live host: jobs runner installer, incl. the explicit `testapp-up` / `testapp-down` (you run it; `HOST` required) | `make host-jobs HOST=<alias> ARGS="install"` |
  | Live host: nightly backup installer and checks, incl. `run-now` and `init-repo` (you run it; `HOST` required) | `make host-backup HOST=<alias> ARGS="install"` |
  | Live host: restore from the backup, runs `restore.sh` as root over ssh (you run it; `HOST` required) | `make host-restore HOST=<alias> ARGS="list"` |
  | Live host: public Access-gate check, run from here (`HOST` required; domain via `PLATFORM_DOMAIN` or `--domain`) | `make host-verify-ingress HOST=<alias> ARGS="--domain D"` |
  | Live host: read-only egress check (`HOST` required) | `make host-verify-egress HOST=<alias> ARGS="--probe"` |
- **GitHub project board:** n/a
- **Issue labels:** n/a
- **PR reviewer:** `GPropersi`
- **Worktree policy:** `build-only`
- **Worktree allowed targets:** `help, lint, test, embed, app-ls`
- **Worktree link:** `n/a`
- **Worktree setup:** `n/a`
- **Worktree teardown:** `n/a`
- **Worktree ports:** `n/a`
- **Worktree guarded targets:** `n/a`
