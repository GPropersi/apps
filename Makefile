.DEFAULT_GOAL := help
.PHONY: help lint test embed app-ls host-app-ls host-deploy-user host-claude-access host-verify-egress host-ingress host-data host-backup host-restore host-verify-ingress

# Live-host targets (host-*) stream a script to the app host over SSH. HOST (an ssh alias) is required, with no
# default alias; ARGS is passed to the script. They are for you to run, never inside a worktree.
# ARGS is expanded unquoted (word-split and globbed), so a --pubkey-file path must not contain spaces or glob
# characters (* ? [).
export HOST
export ARGS

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Public-repo hygiene, embedded-payload drift check, app.yaml registry validation, shellcheck (pinned version) on tracked *.sh
	@platform/lint/check-public-hygiene.sh
	@platform/lint/embed-payloads.sh --check
	@platform/registry/validate-tracked.sh
	@want=$$(cat platform/lint/SHELLCHECK_VERSION); have=$$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p'); \
	[ "$$have" = "$$want" ] || { echo "lint: shellcheck $$want required (platform/lint/SHELLCHECK_VERSION), found $${have:-none}" >&2; exit 1; }
	@git ls-files -z -- '*.sh' | xargs -0 -r shellcheck

test: ## Run every platform/**/test_*.sh (discovered on disk; zero found is an error)
	@tests=$$(find platform -name 'test_*.sh' | sort); \
	[ -n "$$tests" ] || { echo "no platform/**/test_*.sh found" >&2; exit 1; }; \
	rc=0; for t in $$tests; do echo "== $$t"; bash "$$t" || rc=1; done; exit $$rc

embed: ## Regenerate the payloads embedded in platform/host/install-*.sh from their tracked sources
	@platform/lint/embed-payloads.sh

host-deploy-user: ## LIVE: deploy identity installer (HOST=<alias> ARGS="install --pubkey-file PATH"; default status)
	@[ -n "$$HOST" ] || { echo 'usage: make host-deploy-user HOST=<ssh-alias> [ARGS="install --pubkey-file PATH | status | verify"]' >&2; exit 2; }
	@platform/host/install-deploy-user.sh $${ARGS:-status} --host "$$HOST"

host-claude-access: ## LIVE: claude identity installer (HOST=<alias> ARGS="install --pubkey-file PATH"; default status)
	@[ -n "$$HOST" ] || { echo 'usage: make host-claude-access HOST=<ssh-alias> [ARGS="install --pubkey-file PATH | status | verify"]' >&2; exit 2; }
	@platform/host/install-claude-access.sh $${ARGS:-status} --host "$$HOST"

host-ingress: ## LIVE: ingress stack installer (HOST=<alias> ARGS="install | verify | verify --live [--hold]"; default status)
	@[ -n "$$HOST" ] || { echo 'usage: make host-ingress HOST=<ssh-alias> [ARGS="install | status | verify | verify --live [--hold]"]' >&2; exit 2; }
	@platform/host/install-ingress.sh $${ARGS:-status} --host "$$HOST"

host-data: ## LIVE: shared Postgres and Redis installer (HOST=<alias> ARGS="install | verify"; default status)
	@[ -n "$$HOST" ] || { echo 'usage: make host-data HOST=<ssh-alias> [ARGS="install | status | verify"]' >&2; exit 2; }
	@platform/host/install-data.sh $${ARGS:-status} --host "$$HOST"

host-backup: ## LIVE: nightly backup installer (HOST=<alias> ARGS="install | restore-only | verify | run-now | init-repo"; default status)
	@[ -n "$$HOST" ] || { echo 'usage: make host-backup HOST=<ssh-alias> [ARGS="install | restore-only | status | verify | run-now | init-repo"]' >&2; exit 2; }
	@platform/host/install-backup.sh $${ARGS:-status} --host "$$HOST"

host-restore: ## LIVE: restore.sh as root over ssh (HOST=<alias> ARGS="list | app APP --into DB | secrets APP | host-files | full --confirm-destroy")
	@[ -n "$$HOST" ] || { echo 'usage: make host-restore HOST=<ssh-alias> ARGS="list | app APP --into DB | secrets APP | host-files | full --confirm-destroy"' >&2; exit 2; }
	@ssh -o BatchMode=yes -- "$$HOST" sudo -n /opt/platform/backup/restore.sh $$ARGS

app-ls: ## List the registered apps (apps/*/app.yaml), registry only and offline; ignores HOST
	@platform/registry/app-ls.sh

host-app-ls: ## LIVE: registered apps plus live container state over ssh (HOST=<alias>; needs the passwordless sudo the other host-* targets use)
	@[ -n "$$HOST" ] || { echo 'usage: make host-app-ls HOST=<ssh-alias>' >&2; exit 2; }
	@tmp=$$(mktemp) || exit 1; \
	if ! ssh "$$HOST" sudo -n /usr/local/bin/platform ls > "$$tmp"; then rm -f "$$tmp"; echo "host-app-ls: platform ls over ssh failed, no table printed" >&2; exit 1; fi; \
	platform/registry/app-ls.sh --live-from "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

host-verify-ingress: ## LIVE: public Access-gate check from here (HOST=<alias>; domain via PLATFORM_DOMAIN or ARGS="--domain D")
	@[ -n "$$HOST" ] || { echo 'usage: make host-verify-ingress HOST=<ssh-alias> [ARGS="--domain D | --expect-open H | --probe-jobs H"] (or PLATFORM_DOMAIN=D in the environment)' >&2; exit 2; }
	@platform/host/verify-ingress.sh $$ARGS --host "$$HOST"

host-verify-egress: ## LIVE: read-only egress check (HOST=<alias> [ARGS="--probe"])
	@[ -n "$$HOST" ] || { echo 'usage: make host-verify-egress HOST=<ssh-alias> [ARGS="--probe | --probe-inbound"]' >&2; exit 2; }
	@platform/host/verify-egress.sh $$ARGS --host "$$HOST"
