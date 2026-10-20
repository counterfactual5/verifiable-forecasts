# AGENTS.md

Rules for every agent (and human) working in this repository. Short and hard on purpose; details live in `docs/SPEC.md`.

## Focus
- Work only on the current focus: the "第一个功能" section of `docs/SPEC.md` (or "当前焦点" in `docs/plans/路线图.md` once it exists). Do not start later items early.

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
| Spec, stack choice, current focus, assumptions | `docs/SPEC.md` |
| Full Verify | `docs/SPEC.md` "## Full Verify" |
| Chainlink CRE files (bounty: must list in README) | `chainlink/` once created |
