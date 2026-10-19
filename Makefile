.DEFAULT_GOAL := help
.PHONY: help lint test

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Public-repo hygiene check (no secrets / personal data) + shellcheck on tracked *.sh
	@platform/lint/check-public-hygiene.sh
	@git ls-files -z -- '*.sh' | xargs -0 -r shellcheck

test: ## Run every platform/**/test_*.sh (discovered on disk; zero found is an error)
	@tests=$$(find platform -name 'test_*.sh' | sort); \
	[ -n "$$tests" ] || { echo "no platform/**/test_*.sh found" >&2; exit 1; }; \
	rc=0; for t in $$tests; do echo "== $$t"; bash "$$t" || rc=1; done; exit $$rc
