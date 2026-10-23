.PHONY: verify test check fmt analysis analysis-sync demo live

# After `make analysis-sync`, analysis checks run from uv.lock without network access
export UV_LOCKED := 1
export UV_OFFLINE := 1

# Single entry for Full Verify (kicks off to the Foundry suite; grows as subprojects appear)
verify:
	cd contracts && forge fmt --check && forge build && forge test
	cd analysis && uv run ruff check src tests
	cd analysis && uv run pytest tests/ -q
	cd agents && uv run ruff check .
	cd agents && uv run pytest -q

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

# Mainnet-fork round; needs network (MAINNET_RPC_URL), so it stays out of verify
demo:
	bash demo/run.sh

# One live run over the most recent completed mainnet hours; writes dashboard/live-replay.json
live:
	bash demo/live.sh
