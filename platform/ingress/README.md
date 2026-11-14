# platform/ingress/

The front door of the app host: any name under the home domain reaches Traefik on the Pi through one wildcard
Cloudflare Tunnel route, behind one wildcard Cloudflare Access app (family email list, one-time PIN). Everything
here is **run by you**; Claude never touches the live host or the Cloudflare account.

## What is here

| File | Role |
|---|---|
| `compose.yaml` | The Compose project `platform-ingress`: `cloudflared` (token from a host file), `traefik` (routes from files only, no Docker access) and `down-page`. No published ports. Traefik is configured by `TRAEFIK_*` environment variables only; its healthcheck is `traefik healthcheck`. |
| `dynamic.yml` | Traefik file-provider config: the `/_jobs` deny router, the lowest-priority catch-all and the `errors` middleware. |
| `down-page/index.html` | The static "this app is down or does not exist" page. |
| `jobs-paths.table` | The `/_jobs` path variants the tests probe. |
| `env.example` | Placeholder for the host-side `/etc/platform/ingress.env`. |
| `access.env.example` | Placeholder for the host-side `/etc/platform/access.env`. |
| `test_*.sh` | Offline tests of the files above (`make test`); they read the YAML with `../lib/yaml-subset.sh`. |

`test_traefik_dynamic.sh` runs the pinned Traefik for real and needs docker, so it skips (exit 0, loud notice) on a
host without it, as in CI. For the pre-merge run on a docker host use `REQUIRE_DOCKER=1 platform/ingress/test_traefik_dynamic.sh`:
a missing docker, daemon or socket then fails instead of skipping. Traefik there gets no Docker socket at all: routes
come from `app-<app>.yml` files written after it starts, which also proves the file watcher picks them up.

The installer `platform/host/install-ingress.sh` embeds the three payload files; edit the source file and run
`make embed` (`make lint` fails on drift).

## Setup checklist

Order matters: the Access app must exist before the route, so the name is never public even for a moment.

### 1. Cloudflare dashboard (you, in this order)

1. **Access app first.** Zero Trust, Access, Applications: add a self-hosted application for the wildcard
   hostname `*.<your domain>`. Policy: Allow, selector **Emails** (the family list), login method one-time PIN.
   The family list lives only in the dashboard, never in this repo.
2. **Tunnel route.** Create (or open) the remotely managed tunnel and add a public hostname route for
   `*.<your domain>`: Service type **HTTP**, URL `traefik:80` (the Compose service name and the container's
   entrypoint port), **HTTP Host Header override left empty**. Never an IP address.
3. **DNS.** A proxied `*` CNAME to the tunnel (the tunnel's own hostname, shown in the dashboard) if the dashboard did not create it.
4. Copy the tunnel token from the tunnel's page; you paste it into a host file below. It never goes in a chat,
   a tracked file or a command line.

**Reserved names.** A DNS label that already has its own explicit record (for example the apex, `www`, or any name
you created by hand) is not covered by the wildcard, so it cannot be used as a `platform.app` value. If a specific
hostname Access app overrides the wildcard, test it live before relying on it.

### 2. Host-side files (you, on the Pi)

| Path | Owner / mode | Content |
|---|---|---|
| `/etc/platform/cloudflared.token` | `root:64321`, `0640` | the tunnel token (one line) |
| `/etc/platform/ingress.env` | `root`, not group or world writable (`0644`) | `PLATFORM_DOMAIN=<your domain>` (lowercase DNS name) |

#### Host files you create by hand

`/etc/platform/access.env` (root-owned, `0644`, not group or world writable) holds the Cloudflare Access settings
`platform deploy` hands to every app. It needs two values from the Zero Trust dashboard:

- `ACCESS_TEAM_DOMAIN=<team>.cloudflareaccess.com`: the team domain (Zero Trust, Settings, Custom Pages).
- `ACCESS_AUD=<64 hex characters>`: the Application Audience tag (Zero Trust, Access, Applications, the wildcard app,
  Overview).

**Preferred: let `make host-access-env` write it.** Keep the two values once as GitHub environment variables on the
`production` environment (they are identifiers, not credentials, but this repo is public, so never commit them). From
the repo, logged in with `gh`, `gh variable set ACCESS_TEAM_DOMAIN --env production` and the same for `ACCESS_AUD` each
prompt for the value, so it never lands in your shell history. Then, for any host, new or rebuilt:

```
make host-access-env HOST=<alias>
```

It reads the variables (or `ACCESS_TEAM_DOMAIN` and `ACCESS_AUD` from your environment when both are set), validates them
with the rules below, writes the file over ssh with sudo (temp file, `root:root`, `0644`, one `mv`), re-reads it, and
never prints a value. A repeat reports `already`; a file with different content is replaced only with `ARGS="--force"`;
`ARGS="--check"` only compares. It is deliberately a command you run, not a CI step: CI reaches the host only as the
restricted `deploy` login, and this file must stay unwritable by it because it decides how Access identities are checked.

By hand (the fallback, same result): copy `access.env.example`, fill in the two values and

```
sudo tee /etc/platform/access.env >/dev/null
sudo chown root:root /etc/platform/access.env
sudo chmod 0644 /etc/platform/access.env
```

(paste the two lines, Enter, Ctrl-D). Both values are account-specific: never commit them. A deploy refuses to start
when the file is missing, a symlink, group or world writable, or holds a malformed value, and its log names the key and
the file, never the value. `make host-ingress ... ARGS="verify"` checks the file too. The single `ACCESS_AUD` fits only
apps whose Access scope is `access` absent or `family`; a `public` or `restricted` app needs a later template or a
per-app audience.

The ingress installer also needs the `deploy` group (run `make host-deploy-user` first): the
`/opt/platform/ingress/dynamic` directory is `root:deploy` mode `1775` (sticky, group-writable), so `platform deploy`
writes only its own `app-<app>.yml` route files there and cannot replace or delete root's `dynamic.yml`. `verify` and
`verify --live` prove this as the `deploy` user.

**Trust boundary.** The `deploy` identity (CI's restricted login) can author any `*.yml` in that directory, including a
router with a high `priority` that would shadow the `/_jobs` deny or an Access-gated route; the sticky bit protects only
root's `dynamic.yml`. The guard is `install-ingress.sh verify` (and `status`): it fails on any file other than
`dynamic.yml` that is not named `app-<valid-name>.yml` or whose lines are not exactly what `platform deploy` renders
(that app's own router and service, no `priority`, `middlewares` or other key). Run it after any deploy-identity change.

The token group is created by you, once, at the fixed gid `64321` (it must equal `group_add` of `cloudflared` in
`compose.yaml`). It must have **no members**, be **no account's primary group** and **not be the Docker socket's
group**. The installer only verifies this, fail-closed, and prints the commands when something is missing:

```
sudo groupadd --gid 64321 cloudflared-token
sudo install -d -m 0755 -o root -g root /etc/platform
sudo install -m 0640 -o root -g 64321 /dev/null /etc/platform/cloudflared.token
sudo tee /etc/platform/cloudflared.token >/dev/null
echo 'PLATFORM_DOMAIN=<your-domain>' | sudo tee /etc/platform/ingress.env >/dev/null
sudo chmod 0644 /etc/platform/ingress.env
```

(paste the token, Enter, Ctrl-D, for the `tee` of the token file). The stack installs under
`/opt/platform/ingress` and creates the `platform` network (bridge, IPv6 off) if absent. An upgrade from the earlier
socket-proxy layout is automatic: the installer removes the socket-proxy container, the `ingress-proxy` network and
`docker-gid.env`, logs each removal, and `verify` fails while any of them remains. If container DNS goes to a
LAN resolver, list it in `/etc/platform/egress-allow.cidrs` (see `platform/host/README.md`).
Install order for a first app that declares volumes or routes: `make host-deploy-user`, then `make host-jobs`, then
`make host-ingress`, before its first deploy.

### 3. Install and verify

```
make host-ingress HOST=<alias> ARGS="install"
make host-ingress HOST=<alias> ARGS="verify"
make host-ingress HOST=<alias> ARGS="verify --live"
make host-verify-ingress HOST=<alias> ARGS="--domain <your domain>"
```

- `make host-ingress ... ARGS="verify"` runs the on-host checks (files, ownership, container health, no published
  ports, no token in a container's env or command line, DNS). `ARGS="verify --live"` adds routing probes with
  disposable containers (it always cleans them up); `--live --hold` also waits for one real browser login through
  the tunnel.
- `make host-verify-ingress` is the public check, run from your machine: it requests a random unused name like a
  stranger and passes only when the Access login wall is seen. Open, unreachable and unconfirmed each fail with a
  distinct message. `PLATFORM_DOMAIN` in the environment can replace `--domain`.

## Routing and label contract

- **Routing comes only from files.** Traefik reads `dynamic.yml` plus one `app-<app>.yml` per app from
  `/opt/platform/ingress/dynamic`, written by `platform deploy` (router `app-<name>`, rule Host(`<name>.<domain>`),
  entry point `web`, service `app-<name>` to the container's single port). Labels route nothing: an app with
  `traefik.*` labels but no route file answers the friendly 503.
- An app container carries exactly one label, `platform.app=<name>`, used by `platform ls` and scoping, not routing.
- **Apps must not carry `traefik.*` labels.** Defence in depth: they are inert now, but the deploy path still rejects
  any `traefik.*` or `platform.*` image label and validates `platform.app` as a lowercase DNS label
  (`platform/deploy/deploy.sh`, `inspect` phase), and its `docker run` sets the one label itself.
- **A stopped `app-<name>-old` keeps its label.** Labels are immutable, so during a deploy the old container, renamed
  `app-<name>-old` and stopped, still carries `platform.app=<name>`: `platform ls` shows the app `exited` from the swap until
  the commit removes it, and after an interrupted deploy until the next deploy removes or restores it. This is accepted.
- **`/_jobs` is denied** at the edge for every app (case-insensitive, and the normalised and encoded variants
  recorded in `dynamic.yml`); it never reaches the app. The jobs runner is reached another way.
- **502, 503 and 504 are replaced by the friendly page.** Any app response with one of these statuses gets the down
  page body with the status preserved, so templates must not rely on custom 502 to 504 bodies. An unknown app answers
  503 from Traefik (the catch-all). A stopped app answers 503 only because `platform deploy` renders a Traefik health
  check on the app's `health_path` into its route file: Traefik then drops the unhealthy server within a few seconds
  (interval 5s, timeout 3s) and answers 503, which Cloudflare passes through with the friendly body. Cloudflare
  replaces an origin 502 or 504 with its own error page (overriding that needs an Enterprise plan or a paid
  Custom Error Rule), so a stopped app with no `health_path`, and the first seconds after a crash, show Cloudflare's
  "Bad gateway" page instead. `install-ingress.sh verify` accepts only the health check lines `platform deploy`
  renders, with the path restricted to what `validate-app-yaml.sh` allows.
  - `health_path` therefore also gates routing: it must stay cheap, unauthenticated and answer 2xx or 3xx within 3s,
    because Traefik probes it every 5s and a failing or slow response drops the app to the down page until it recovers.
  - An app deployed before this change keeps its old route file, and a stopped one still shows Cloudflare's 502 page,
    until its next deploy.
  - Rollout order: CI runs the copy of `deploy.sh` installed by `make host-deploy-user`, so a merge changes nothing
    live until that runs. Run `make host-ingress ARGS="install"` (the guard that accepts the health check lines)
    before `make host-deploy-user`, otherwise a later `verify` fails on the new lines.

## Guarantee scope

The ingress stack publishes **no ports**; all inbound traffic arrives through the tunnel. Container-to-host
traffic (INPUT, not forwarded) is still out of scope, as in the egress guarantee (`platform/host/README.md`). The
Access gate is verified from outside by `make host-verify-ingress`; routing and the `/_jobs` denial by
`verify --live`.

**Environment exposure.** Traefik has no Docker API access of any kind, so it cannot read any container's
environment variables.

## Rotating the tunnel token

Get the new token from the tunnel's page in the Cloudflare dashboard, then on the Pi overwrite
`/etc/platform/cloudflared.token` in place (keep owner `root:64321` and mode `0640`; `sudo tee` on the existing
file keeps both), and restart only cloudflared:

```
sudo docker compose -p platform-ingress -f /opt/platform/ingress/compose.yaml --env-file /etc/platform/ingress.env restart cloudflared
```

Then run `make host-ingress HOST=<alias> ARGS="verify"`. Revoke the old token in the dashboard.

## Rollback

1. Stop the stack on the Pi (removes the ingress containers; the `platform` network stays (it is external to the stack, IPv6 off,
   and apps join it later); no firewall rule is touched):
   ```
   sudo docker compose -p platform-ingress -f /opt/platform/ingress/compose.yaml --env-file /etc/platform/ingress.env down
   ```
2. In the Cloudflare dashboard remove the wildcard route and the `*` DNS record (and the Access app if you are
   retiring the domain). These two dashboard steps are documented only; they are not exercised by the acceptance
   run, which exercises only the stack-stop leg.

After step 1 the Pi runs no ingress containers and the firewall rules are unchanged.
