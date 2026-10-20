# chainlink/

Chainlink CRE (Custom Runtime Environment) workflow for the Chainlink sponsor bounty at ETH Shenzhen 2026.

**Not implemented yet.** The 2026 Chainlink hackathon rules accept a **CLI-simulated** CRE workflow, so the
bounty does not depend on this directory working against a live CRE deployment. The project must not depend on
CRE being available either.

## Planned contents

| File | What it does |
|---|---|
| `workflow.ts` | The CRE workflow: read the round's window definition and the latest base fee, run the forecaster, return the probability vector. |
| `README.md` | How to run the workflow with the CRE CLI, and what it returns. |
| `simulate.sh` | Local simulation of the workflow against Anvil, so the demo never needs network access. |

## Boundary

- **Depends on:** the `agents/` forecast output and the `analysis/` parameter file, both as data.
- **Depends on nothing from:** the contract source, `dashboard/`.
- This directory is a **consumer** of the rest of the project. Nothing in `contracts/`, `agents/` or
  `analysis/` may import from it.

## Bounty requirement

The root `README.md` must list this directory and explain how to run the workflow, even if the workflow is
only simulated. That listing is checked in the repository README, not here.

## Rules this must respect

- 2026 Chainlink hackathon: Automation and Functions tracks are retired; **CRE** is the current surface.
- The workflow must be runnable in simulation from a clean checkout.
