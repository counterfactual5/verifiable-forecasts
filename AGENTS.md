# AGENTS.md

Rules for every agent (and human) working in this repository. Short and hard on purpose; details live in `docs/SPEC.md` and `docs/plans/实施计划.md`.

## Focus
- The current focus is whatever `docs/plans/路线图.md` says; scope is set by `docs/plans/实施计划.md` and `docs/SPEC.md`. Do not start later items early.

## Structure
- Subprojects are independent: `contracts/` (Foundry) must not depend on anything outside itself; `agents/` and `analysis/` never import each other. Entry scripts stay thin: wiring only.
- Window length and bucket bounds are constructor/function parameters, never hardcoded magic numbers in contracts.
- Share late: extract shared code only with two real users. No empty directories, no `utils` / `common` drawers. Exceptions listed here with date, scope, reason.

## Code
- Identifiers and comments in English. A comment states a constraint the code cannot show, never what the next line does.
- Do not weaken, skip or delete tests to make the suite pass. New contract behavior ships with tests that were first proven able to fail.
- Settlement math must stay integer-only and overflow-safe (`0.8.28` checked arithmetic); document every scaling factor (1e18 probability scale, wei base-fee units) at the definition site.
- Claims that something is "not worth it" or "mainstream" need a source with an evidence grade (A–D, X); otherwise mark them `[待证据]` and do not use them to drop a requirement.

## Verify before done
- Run `make check && make test` and see it pass.
- The Full Verify stays one line; new steps (ruff/pytest for `agents/`, `analysis/`) go into a root `make verify` target once those subprojects exist, not a second command to remember.

## Git
- Commit only your own changes, by explicit path. If a file also holds someone else's uncommitted edits, stage your hunks only (`git add -p`).
- Never run `git add -A` outside the kickoff initial commit; never `git commit -a`, `git stash`, `git restore`, `git checkout -- <path>`, `git reset --hard`; never reformat or revert changes you did not make.
- Never commit secrets (`.env*` except examples, keys, RPC keys), files over 5 MB, `out/`/`cache/` build output, or fetched market data under `data/` (ignored).
- Never push, create remotes or deploy without an explicit instruction.
- Agent plans and drafts stay in git-ignored `.local/` directories, never in tracked docs.

## Where to find
| What | Where |
|---|---|
| Spec, stack choice, assumptions | `docs/SPEC.md` |
| Detailed design (Δ/N, vol formula, zk public inputs, ERC-8004, Chainlink) | `docs/plans/实施计划.md` |
| Current focus | `docs/plans/路线图.md` |
| Full Verify | `docs/SPEC.md` "## Full Verify" |
| Market contract, shared math | `contracts/src/VolMarket.sol`, `contracts/src/lib/MarketMath.sol` |
| EZKL-generated verifiers (do not edit or format by hand) | `contracts/src/verifier/` |
| Shared vol fixture (contracts, agents, analysis all read it) | `contracts/test/fixtures/vol_rv_cases.json` |
| Forecasting agents, models, EZKL build | `agents/` (see `agents/README.md`) |
| Verified facts (pool history, observe gas, ERC-8004, Chainlink) | `spikes/facts/FACTS.md` |
| EZKL feasibility measurements | `spikes/ezkl/README.md` |
| Swap fetch and vol bound calibration | `analysis/` (see `analysis/README.md`) |
