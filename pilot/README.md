# FCC Pilot Overlay

This directory is Karp's qualification layer for FCC. It does not change FCC production behavior.

Pinned upstream: `ba4b934147855025df30bbca3ad6d436158fe671`
Fork: `Dash-bee/free-claude-code`
Branch: `karp/fcc-pilot-v1`

## Current status
- Gate 0 supply-chain pin: PASS
- Gate 1 deterministic routing/fault contracts: PASS (189 tests, global no-egress guard)
- Gate 2 live provider canary: NOT RUN
- Gate 3 live cost/quota accounting: NOT RUN
- Gate 4 unattended coding-worker soak: NOT RUN
- Gate 5 shadow production: NOT RUN
- Production use: NOT AUTHORIZED

## Deterministic run

```powershell
powershell -ExecutionPolicy Bypass -File .\pilot\run_contracts.ps1
```

The runner verifies the pinned source boundary, Python 3.14.7, and executes both the
pilot fault matrix and upstream FCC fallback/routing contracts. Evidence is written
under `pilot/results/` and is intentionally ignored by git.

Read `PILOT_CONTRACT.md` before enabling any live provider. Live qualification must
use disposable repositories, hard spend caps, machine-verifiable tasks, and scratch-only output.
