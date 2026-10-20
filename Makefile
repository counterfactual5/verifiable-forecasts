.PHONY: verify test check fmt analysis analysis-sync

# After `make analysis-sync`, analysis checks run from uv.lock without network access
export UV_LOCKED := 1
export UV_OFFLINE := 1

# Single entry for Full Verify (kicks off to the Foundry suite; grows as subprojects appear)
verify:
	cd contracts && forge fmt --check && forge build && forge test
	cd analysis && uv run ruff check src tests
	cd analysis && uv run pytest tests/ -q

test:
	cd contracts && forge test

check: verify

fmt:
	cd contracts && forge fmt

analysis:
	cd analysis && uv run ruff check src tests
	cd analysis && uv run pytest tests/ -q

analysis-sync:
	cd analysis && env -u UV_OFFLINE uv sync --locked
