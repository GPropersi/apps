# apps

Self-hosted app platform: platform code, templates and apps.

## Layout

| Path | Purpose |
|---|---|
| `platform/` | Host and platform scripts (deploy entry point, jobs runner, backups, status page), the ingress and shared data (Postgres, Redis) stacks, the app registry and repo lint |
| `apps/` | One directory per app, `apps/<name>/` |
| `templates/` | Starting points used to scaffold a new app |
| `.github/workflows/` | CI (and, later, build and deploy on pushes to `main`) |

Run `make help` for the available targets.

## Public repo rules

This repository is **public**. Treat everything committed here as visible to the world.

- No secrets, tokens, keys, passwords or personal data, ever. Credentials live in host-side files
  and repo secrets, never in the tree.
- No IP addresses, tailnet names or ssh-scheme URLs. `make lint` fails on them (see
  `platform/lint/check-public-hygiene.sh`); an entry in `platform/lint/hygiene-allow.txt` is only
  for a genuinely public value, with the reason in the PR.
- Changes reach `main` only through a reviewed pull request with a green `ci` check.
- Workflows never use `pull_request_target`, and deploy jobs run only for pushes to `main`,
  never for fork pull requests.
