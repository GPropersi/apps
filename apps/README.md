# apps/

One directory per app: `apps/<name>/`. Each app carries its own `app.yaml` and adds its own
path-glob row to the push gate in `CLAUDE.md` when it lands.

The `app.yaml` schema (every field, the allowed values and the reserved names) is documented in
[`platform/registry/README.md`](../platform/registry/README.md), with a valid example in
`platform/registry/app.yaml.example`. `make lint` validates every tracked `apps/*/app.yaml`.
