.DEFAULT_GOAL := help
.PHONY: help lint test

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Public-repo hygiene check (no secrets / personal data) + shellcheck on tracked *.sh
	@platform/lint/check-public-hygiene.sh
	@git ls-files -z -- '*.sh' | xargs -0 -r shellcheck

test: ## Unit tests for the hygiene check
	@platform/lint/test_check_public_hygiene.sh
