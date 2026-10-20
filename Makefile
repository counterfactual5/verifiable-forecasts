.PHONY: verify test check fmt analysis

# Single entry for Full Verify (kicks off to the Foundry suite; grows as subprojects appear)
verify:
	cd contracts && forge fmt --check && forge build && forge test

test:
	cd contracts && forge test

check: verify

fmt:
	cd contracts && forge fmt

# analysis/ is a separate uv project; its suite joins the Full Verify once it exists
analysis:
	cd analysis && uv run pytest tests/ -q
