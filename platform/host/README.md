# platform/host/

Scripts for the app host (a Debian Raspberry Pi running Docker). Everything here is **run by you**, with sudo on
the host; Claude never runs the live-host targets (they are denied in a worktree, and they change the host).

## What is here

| File | Role |
|---|---|
| `platform.sh` | The `platform` dispatcher: the only command the `deploy` identity can run. Validates one unsplit string against an allowlist. `new-db <app>` hands over to `/opt/platform/data/new-db.sh` (exit 1 with "run `make host-data ... install`" when it is not installed). `ls` prints one TSV row per labelled app (`app`, `state`, `health`; contract in [`../registry/README.md`](../registry/README.md)) and exits 1 on a docker failure. `make host-app-ls HOST=<alias>` runs it over ssh as `sudo -n /usr/local/bin/platform ls`, so it needs the passwordless sudo the other `host-*` targets use. `deploy` and `rollback` are placeholders that exit 3 (not implemented) until later steps. |
| `login-shell.sh` | Root-owned validating login shell of `deploy` (`platform-login`). Never starts a shell; hands one `-c` command to the dispatcher. |
| `install-deploy-user.sh` | Creates the `deploy` user, its forced-command key and the `Match User deploy` sshd drop-in. |
| `claude-access.sh`, `claude-helper.sh` | Validating wrapper (also the login shell) and root helper for the `claude` debugging identity: `ps`, `stats`, `status`, `logs <app> [lines]`, `restart <app>`. |
| `install-claude-access.sh` | Creates the `claude` user, its key and the `Match User claude` sshd drop-in; prints one sudoers line for you to install. |
| `install-ingress.sh` | Installs the ingress stack (Traefik, cloudflared, socket proxy, down page) under `/opt/platform/ingress` and starts it. Never creates the tunnel token or its group (`64321`); checks both fail-closed and prints how to create them. `install`, `status`, `verify`, and `verify --live [--hold]` (disposable containers prove routing and the down-page fallbacks; `--hold` also waits for one real login through the tunnel). Run it with `make host-ingress HOST=<alias> ARGS="..."`. |
| `install-data.sh` | Installs the shared data stack (one Postgres, one Redis) under `/opt/platform/data` and starts it on the `platform` network. Never creates the two admin password files or their groups (`64322` admin secrets, `64323` app secrets); checks them, the `deploy` user and the network fail-closed and prints how to create them. Creates `/var/lib/platform` (`root:root 0755`) and the secrets root `/var/lib/platform/secrets` (`deploy:64323 2710`, setgid, so `platform new-db` as `deploy` needs no `chgrp`). `install`, `status`, `verify` (published ports, labels, networks, secrets in Env/Cmd/Healthcheck, Redis ACL users, eviction, AOF, Postgres logging and PUBLIC `CONNECT`, installed modes; a `WARN:` at about 80% of Redis `maxmemory` never fails it). Run it with `make host-data HOST=<alias> ARGS="..."`. Stack details: [`../data/README.md`](../data/README.md). |
| `install-backup.sh` | Installs the nightly backup to R2: the pinned `restic` (sha256-checked), `/opt/platform/backup/` (`backup.sh`, `restore.sh`, `window.env`), the work directories and `platform-backup.service` plus `platform-backup.timer` (03:35 inside the 03:30-05:00 window). Never writes `/etc/platform/backup.env`; refuses unless it is `root:root 0600` with all six keys as literal values. `install`, `restore-only` (restic and `restore.sh` only, for a rebuilt host), `status`, `verify` (payload bytes, restic version and hash, timer enabled and inside the window, last run not `failed` or older than 36h), `run-now` (`backup.sh manual` under `systemd-run` with the nightly's limits) and `init-repo` (one explicit `restic init`). Run it with `make host-backup HOST=<alias> ARGS="..."`; restore with `make host-restore HOST=<alias> ARGS="list"` (runs `restore.sh` as root over ssh). Details: [`../backup/README.md`](../backup/README.md), [`../backup/RUNBOOK.md`](../backup/RUNBOOK.md). |
| `verify-ingress.sh` | Client-side, fail-closed public check: a random unused name under your domain must show the Cloudflare Access login wall (open, unreachable and unconfirmed each fail distinctly). Runs on your machine, makes no ssh call, is not embedded. Run it with `make host-verify-ingress HOST=<alias> ARGS="--domain <domain>"` (or `PLATFORM_DOMAIN` in the environment; there is no default domain). `--expect-open HOST` marks a deliberately public name; `--probe-jobs APP-HOST` only prints manual `/_jobs` commands. |
| `verify-egress.sh` | Read-only check that the host firewall closes container-to-LAN egress. |

The installers embed their payloads (dispatcher, wrapper, helper, for the ingress installer compose.yaml,
dynamic.yml and the down page's index page, and for the data installer compose.yaml, pg_hba.conf,
redis-entrypoint.sh, reserved-names.txt and new-db.sh, and for the backup installer backup.sh, restore.sh,
window.env, the service unit and the timer unit) because the host has no checkout: edit the
source file, run `make embed`, and `make lint` fails if an embedded copy differs from its source.

## Identities

- `deploy`: dedicated user in the `docker` group (root-equivalent, accepted), no sudo, locked password. Two
  layers: the forced command in `authorized_keys` (read from the root-owned `/etc/ssh/authorized_keys.d`) and a
  root-owned validating login shell, so it stays safe even if a Tailscale SSH rule later reaches it (Tailscale
  SSH ignores `authorized_keys` forced commands). The installer is strict: an existing `deploy` account must
  have groups exactly `deploy docker` and a nonzero uid, otherwise it refuses. The sshd drop-in pins
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` and
  `AuthorizedKeysCommand none` for the user.
- `claude`: read-mostly debugging login, **LAN OpenSSH only** with its own key and a forced command. Not in
  `docker` or `sudo`; one sudoers line allows only the root helper. It stays out of every Tailscale `ssh` rule.
- Containers: app containers carry exactly one label `platform.app=<name>`; infrastructure containers
  (Traefik, cloudflared, Postgres, Redis) are never labelled. `claude` logs and restarts match only that label.

## User-run checklist

Keep a second SSH session open while installing (an `sshd -t` failure restores the previous drop-in and exits 1
without reloading). Over `--host` the SSH account needs passwordless sudo; otherwise copy the script to the host
and run it there directly.

1. Create the egress files (below), then from the stronghold run `make host-base HOST=<alias> ARGS=install` so
   the host base renders the firewall rules from them.
2. Create a key pair for each identity on your client. The private keys never leave it; only the public key file
   is passed to the installer.
3. `make host-deploy-user HOST=<alias> ARGS="install --pubkey-file <path-to-deploy-pub>"`
4. `make host-claude-access HOST=<alias> ARGS="install --pubkey-file <path-to-claude-pub>"`, then install the
   sudoers line it prints (validated with `visudo -cf` when visudo exists; a SKIP line says otherwise; you copy it into place yourself).
5. `make host-deploy-user HOST=<alias> ARGS=verify`, `make host-claude-access HOST=<alias> ARGS=verify` and
   `make host-verify-egress HOST=<alias>` must all exit 0. Optional: `ARGS="--probe"` on the egress check starts
   a throwaway container, and `ARGS="verify --live --identity <private-key-file>"` on `host-claude-access` runs an
   end-to-end check with a disposable labelled container (both clean up after themselves).

6. Ingress (tunnel, Traefik, Access): follow [`../ingress/README.md`](../ingress/README.md), which has the
   Cloudflare dashboard checklist (Access app first, then route and DNS), the token and env files with their
   owners and modes, the label contract, token rotation and rollback. In short:
   `make host-ingress HOST=<alias> ARGS="install"`, then `ARGS="verify"` (on-host) and
   `make host-verify-ingress HOST=<alias> ARGS="--domain <domain>"` (public gate) must both exit 0.
   `ARGS="verify --live"` adds routing probes with disposable containers, and `--hold` waits for one real login.
   The ingress stack publishes no ports; container-to-host traffic stays out of scope (see Guarantee scope).

7. Shared data (Postgres and Redis): needs steps 3 and 6 done first (the `deploy` user and the `platform` network).
   Create the two groups, once, with no members: `sudo groupadd --gid 64322 platform-data-admin` and
   `sudo groupadd --gid 64323 platform-app-secrets`. Create the two admin password files, each a single line,
   `root:64322`, mode `0640` (`sudo install -m 0640 -o root -g 64322 /dev/null <file>`, then
   `openssl rand -hex 24 | sudo tee <file> >/dev/null`): `/etc/platform/postgres-admin.password` and
   `/etc/platform/redis-admin.password`. The installer never writes them. Then
   `make host-data HOST=<alias> ARGS="install"` and `ARGS="verify"` (both exit 0). `install` lists every missing
   input together, with these commands, and installs nothing until they are all in place. `install` also writes
   a sysctl drop-in file named `99-platform-redis` (`vm.overcommit_memory = 1`) and sets the live value, so it
   survives a reboot. `verify` WARNs (exit status unchanged) when the live value is not 1 or the drop-in is missing or
   different; re-run `install` to fix it.
8. After this merges and before you use `platform new-db` or `platform ls`, roll out the updated dispatcher:
   `make host-deploy-user HOST=<alias> ARGS="install --pubkey-file <path-to-deploy-pub>"`, then `ARGS=verify`.
   `platform new-db` also needs the helper from step 7: re-run `make host-data HOST=<alias> ARGS="install"` once so
   `/opt/platform/data/new-db.sh` is installed (`verify` checks its owner, mode and bytes).

9. Nightly backup to R2: needs step 7 done first. Create `/etc/platform/backup.env` yourself (`root:root`, mode `0600`,
   six literal `KEY=VALUE` lines, no quotes; see [`../backup/RUNBOOK.md`](../backup/RUNBOOK.md)); the installer never
   writes it. Then `make host-backup HOST=<alias> ARGS="install"`, once `ARGS="init-repo"` (creates the restic
   repository; never automatic), `ARGS="run-now"` (one manual backup) and `ARGS="verify"` (exit 0). A
   `Persistent=true` catch-up run can fire when `install` enables the timer; it is flagged as outside the window.
   `install-data.sh` is not placed on the host, so the final `install-data verify` that `restore.sh full` would run is
   skipped and logged; run `make host-data HOST=<alias> ARGS="verify"` after a full restore instead.
   `install` (and `restore-only`) downloads the pinned `restic` release on the host, so the host needs outbound
   network access at install time; without it, place the binary by hand (download the pinned release elsewhere and
   copy it to the path `install-backup.sh` names, then re-run; the sha256 check still applies).
   `ARGS` for `host-restore` is re-parsed by the remote shell as root, so its words must be plain tokens (no spaces
   or shell metacharacters).

`HOST` is required for every `host-*` target, with no default alias; each exits 2 with a usage message when it
is unset. For the five installers, `status` (the default) reports every check without failing and `verify`
exits 1 on any failure; the egress check has no mode and always exits 1 on a failure. `--probe` needs the LAN
default gateway to fall inside a deny range (otherwise it exits 2 rather than pass vacuously).

`install-deploy-user.sh`, `install-claude-access.sh`, `install-ingress.sh`, `install-data.sh` and
`install-backup.sh` intentionally duplicate shared scaffolding, because each is streamed standalone over
`ssh bash -s` and cannot source a common file. A fix to one must be mirrored in the others.

## Streaming invocation

`--host ALIAS` streams the script over one `ssh ALIAS bash -s` call (BatchMode, no tty), except
`install-claude-access.sh verify --live`, which makes several ssh calls from the client. The make targets are
thin wrappers around it, for example:

```
make host-verify-egress HOST=<alias>
make host-verify-egress HOST=<alias> ARGS="--probe"
```

`ARGS` is expanded unquoted, so a `--pubkey-file` path must not contain spaces or glob characters (`*`, `?`, `[`).

For `--pubkey-file`, the local file is read and validated on the client and its content is forwarded as a quoted
argument; the host re-validates it before writing. An optional `--from PATTERN` limits the key to matching
source addresses.

## Egress rules

The container egress rules are generated by `.claude/scripts/server-host-base.sh` in the stronghold (into the
DOCKER-USER chain rules file); this repo only verifies them. Two host-side files, both created and owned by you
(root, mode 0644; they hold ranges, not secrets):

- `/etc/platform/egress-deny.cidrs`: **required**, the ranges containers must not reach.
- `/etc/platform/egress-allow.cidrs`: **optional**, a resolver exception only. Each range gets RETURN rules for
  udp and tcp port 53 and nothing else (this lets Docker's embedded resolver reach a LAN DNS server).

Grammar, shared by both files:

- One IPv4 CIDR per line with an explicit prefix of 1 to 32 and zero host bits (canonical form; `/0`, a bare
  address, IPv6 and a non-canonical range such as a host address with a `/24` prefix are invalid).
- `#` comments and blank lines are ignored, but CRLF and trailing whitespace are rejected on every line,
  comments included. Anything else is invalid: CRLF line endings, trailing whitespace, a
  duplicate line.
- Overlapping distinct ranges are allowed.

A missing, empty or invalid deny file is an error: host-base leaves the existing rules and chain untouched and
exits non-zero with instructions. On a fresh host (no rules file yet) it installs the inbound-only backstop,
warns loudly that egress is not applied, and exits non-zero. An absent allow file is fine; a present but invalid
one is an error. No address appears in any tracked file: the ranges come from these files at run time.

Container-to-container traffic is exempted with four interface-pair rules ahead of the drops; there is no bare
output-interface exemption (it would reopen the inbound backstop).

### Rollback (manual only)

Emptying or removing the deny file never removes rules (the run is refused). Emptying or removing the allow
file is valid, and the next install drops the port 53 exceptions. Either edit the files and re-run `make
host-base HOST=<alias> ARGS=install` from the stronghold, or restore the pre-egress copy: copy
`/etc/docker/docker-user.rules.bak` back over `/etc/docker/docker-user.rules`, run `sudo iptables -F DOCKER-USER`
(a `--noflush` restore does not clear a chain the file declares, so the egress rules would otherwise stay), then load it with `sudo
iptables-restore --noflush /etc/docker/docker-user.rules`. Run the flush and the restore back to back (for example
`sudo iptables -F DOCKER-USER && sudo iptables-restore --noflush /etc/docker/docker-user.rules` on one line): the
chain is empty between them, so the inbound backstop is briefly absent (never restart `docker-user-firewall.service`, docker
requires it), and do not re-run `host-base install` afterwards (it would re-render the egress rules). The `.bak` is written only when the rendered rules differ from the live
file, and an existing `.bak` is never overwritten, so repeated installs keep the first replaced (pre-egress)
file as the backup.

### Guarantee scope

The egress guarantee covers **forwarded traffic** (container to LAN or other hosts) only. Container-to-host
traffic (the host's own LAN address, the bridge gateway, sshd) is INPUT, not DOCKER-USER: it is out of scope and
accepted. IPv6 is out of scope: `verify-egress.sh` asserts the Docker daemon has IPv6 disabled so the
iptables-only rules cannot be bypassed.
