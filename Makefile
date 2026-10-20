.PHONY: verify test check fmt

# Single entry for Full Verify (kicks off to the Foundry suite; grows as subprojects appear)
verify:
	cd contracts && forge fmt --check && forge build && forge test

test:
	cd contracts && forge test

check: verify
	cd contracts && forge fmt --check && forge build && forge test

fmt:
	cd contracts && forge fmt
