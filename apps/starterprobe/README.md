# go-react template

The default app starting point: a Go server (chi, pgx + sqlc, goose) that embeds a Vite + React page.
## Migrations

Migrations live in `migrations/*.sql` (goose format) and are embedded in the binary. The server applies them on start,
before it opens the listener; a failed migration exits non-zero, so the deploy health check fails and the old
container is restored.

**Rule: every migration must stay compatible with the previous version of the app.** A rollback restores the old
container but never reverts the schema, so the old code runs against the new schema. Add columns and tables first,
and remove or rename them in a later release.

## Queries (sqlc)

Queries are in `sql/queries.sql`; the generated Go in `internal/app/db/` is committed. After changing either the
queries or the migrations, regenerate with `make app-sqlc TEMPLATE=go-react` (the pinned generator image; needs
docker).

## Starting an app from this template

`make app-new NAME=<name> PURPOSE="<one line>"` copies this directory to `apps/<name>/` and replaces the template's placeholder
app name with yours (see [`../README.md`](../README.md)). This template supports only `access` absent or `family` in
`app.yaml`: it validates one shared Cloudflare Access audience, and `make lint` refuses `public` and `restricted`.
`internal/platform/` is the shared helper package; never edit it inside an app (a lint compares it with this
directory).

Access settings are account-specific and never committed. Create `/etc/platform/access.env` on the host once
(`ACCESS_TEAM_DOMAIN` and `ACCESS_AUD`); deploy passes them to every app, and an app without them refuses to start.

## Local development

The production build never compiles the dev identity code. For local work run the Go server with the `dev` build tag, which
takes the identity from `ACCESS_DEV_EMAIL` instead of a Cloudflare Access JWT, and the Vite dev server (which proxies
`/api` and `/healthz` to :8080) from `web/`:

```
ACCESS_DEV_EMAIL=you@example.test go run -tags dev ./cmd/server   # also needs the DB_*, REDIS_* and secret files
npm --prefix web run dev
```

Never use `-tags dev` in the Dockerfile or any deploy build. Tests: `make test-app APP=<name>` (Go with and without the
`dev` tag, the web unit tests, sqlc drift, and the final image against real Postgres and Redis). Jobs follow
[`platform/jobs/CONTRACT.md`](../../platform/jobs/CONTRACT.md); regenerate sqlc with `make app-sqlc APP=<name>`.

## Server

`GET /healthz` needs no sign-in. `/api/*` needs a Cloudflare Access identity. The server never answers 502, 503 or 504
itself, because the edge replaces those bodies with the platform down page. The listener port is 8080.
