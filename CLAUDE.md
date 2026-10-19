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
- **Container runtime:** n/a
- **App URL (Playwright MCP):** n/a
- **Test login:** n/a
- **Commands:**
  | Purpose | Command |
  |---|---|
  | Help | `make help` |
  | Lint (public-repo hygiene + embed drift + shellcheck) | `make lint` |
  | Tests (every `platform/**/test_*.sh`) | `make test` |
  | Regenerate embedded installer payloads | `make embed` |
- **GitHub project board:** n/a
- **Issue labels:** n/a
- **PR reviewer:** `GPropersi`
- **Worktree policy:** `build-only`
- **Worktree allowed targets:** `help, lint, test, embed`
- **Worktree link:** `n/a`
- **Worktree setup:** `n/a`
- **Worktree teardown:** `n/a`
- **Worktree ports:** `n/a`
- **Worktree guarded targets:** `n/a`
