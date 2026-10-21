# platform/ingress/

The front door of the app host: any name under the home domain reaches Traefik on the Pi through one wildcard
Cloudflare Tunnel route, behind one wildcard Cloudflare Access app (family email list, one-time PIN). Everything
here is **run by you**; Claude never touches the live host or the Cloudflare account.

## What is here

| File | Role |
|---|---|
| `compose.yaml` | The Compose project `platform-ingress`: `cloudflared` (token from a host file), `traefik`, a read-only `socket-proxy` for the Docker API (on an internal network only Traefik reaches) and `down-page`. No published ports. Traefik is configured by `TRAEFIK_*` environment variables only; its healthcheck is `traefik healthcheck`. |
| `dynamic.yml` | Traefik file-provider config: the `/_jobs` deny router, the lowest-priority catch-all and the `errors` middleware. |
| `down-page/index.html` | The static "this app is down or does not exist" page. |
| `jobs-paths.table` | The `/_jobs` path variants the tests probe. |
| `env.example` | Placeholder for the host-side `/etc/platform/ingress.env`. |
| `test_*.sh`, `yaml-subset.sh` | Offline tests of the files above (`make test`). |

`test_traefik_dynamic.sh` runs the pinned Traefik for real and needs docker, so it skips (exit 0, loud notice) on a
host without it, as in CI. For the pre-merge run on a docker host use `REQUIRE_DOCKER=1 platform/ingress/test_traefik_dynamic.sh`:
a missing docker, daemon or socket then fails instead of skipping. It routes Traefik through a socket-proxy built from
the production image and allowlist, so the host Docker socket is never mounted into Traefik.

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

(paste the token, Enter, Ctrl-D, for the `tee` of the token file). `DOCKER_GID` is not yours to set: the installer derives it from the socket's
group with `stat` and stores it in `/opt/platform/ingress/docker-gid.env`. The stack installs under
`/opt/platform/ingress` and creates the `platform` network (bridge, IPv6 off) if absent. If container DNS goes to a
LAN resolver, list it in `/etc/platform/egress-allow.cidrs` (see `platform/host/README.md`).

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

## Label contract

- An app container carries exactly one label, `platform.app=<name>`, and is then served at
  `https://<name>.<domain>` on its single exposed port.
- **Traefik sees only containers with `platform.app`.** Traefik, cloudflared, the socket proxy, the down page and
  later Postgres and Redis are unlabelled and never become routers.
- **Apps must not carry `traefik.*` labels.** An app-supplied label could shadow the `/_jobs` deny (a
  higher-priority router would bypass it). Deploy-path requirement: the deploy path must reject any `traefik.*`
  label, and must validate `platform.app` as a lowercase DNS label, before an app is deployed. Nothing in the
  ingress stack enforces either rule.
- **`/_jobs` is denied** at the edge for every app (case-insensitive, and the normalised and encoded variants
  recorded in `dynamic.yml`); it never reaches the app. The jobs runner is reached another way.
- **502, 503 and 504 are replaced by the friendly page.** Any app response with one of these statuses gets the down
  page body with the status preserved, so templates must not rely on custom 502 to 504 bodies. A stopped or unknown
  app answers 503 from Traefik.

## Guarantee scope

The ingress stack publishes **no ports**; all inbound traffic arrives through the tunnel. Container-to-host
traffic (INPUT, not forwarded) is still out of scope, as in the egress guarantee (`platform/host/README.md`). The
Access gate is verified from outside by `make host-verify-ingress`; routing and the `/_jobs` denial by
`verify --live`.

**Environment exposure.** Traefik can read every container's environment variables through the socket proxy
(the allowlist includes `GET /containers/<id>/json`, which the Docker provider needs), until the file-provider
migration (master plan Step 11). No app may rely on env-only secrets being hidden from the ingress tier.

## Rotating the tunnel token

Get the new token from the tunnel's page in the Cloudflare dashboard, then on the Pi overwrite
`/etc/platform/cloudflared.token` in place (keep owner `root:64321` and mode `0640`; `sudo tee` on the existing
file keeps both), and restart only cloudflared:

```
sudo docker compose -p platform-ingress -f /opt/platform/ingress/compose.yaml --env-file /etc/platform/ingress.env --env-file /opt/platform/ingress/docker-gid.env restart cloudflared
```

Then run `make host-ingress HOST=<alias> ARGS="verify"`. Revoke the old token in the dashboard.

## Rollback

1. Stop the stack on the Pi (removes the ingress containers; the `platform` network stays (it is external to the stack, IPv6 off,
   and apps join it later); no firewall rule is touched):
   ```
   sudo docker compose -p platform-ingress -f /opt/platform/ingress/compose.yaml --env-file /etc/platform/ingress.env --env-file /opt/platform/ingress/docker-gid.env down
   ```
2. In the Cloudflare dashboard remove the wildcard route and the `*` DNS record (and the Access app if you are
   retiring the domain). These two dashboard steps are documented only; they are not exercised by the acceptance
   run, which exercises only the stack-stop leg.

After step 1 the Pi runs no ingress containers and the firewall rules are unchanged.
