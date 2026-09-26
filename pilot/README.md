# FCC Pilot Overlay

This directory is Karp's qualification layer for FCC. It does not change FCC production behavior.

Pinned upstream: `ba4b934147855025df30bbca3ad6d436158fe671`
Fork: `Dash-bee/free-claude-code`
Branch: `karp/fcc-pilot-v1`

## Current status
- Gate 0 supply-chain pin: PASS
- Gate 1 deterministic routing/fault contracts: PASS (195 tests, global no-egress guard)
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

## Vertex ADC fail-closed preflight

No live Vertex/Gemini pilot request is authorized outside `run_vertex_canary.ps1`.
That launcher runs `vertex_preflight.ps1` first and refuses to continue unless every gate passes.

The preflight requires:
- the exact dedicated project ID and the project label `karp-purpose=fcc-pilot`;
- the exact linked billing account, with billing enabled and the account open;
- `aiplatform.googleapis.com` enabled;
- the selected model and location to be on the tracked allowlists;
- the isolated ADC/config paths under `.auth/google-vertex`;
- one monthly budget named `FCC Pilot Vertex Spend Cap`, scoped only to the pilot
  project and Vertex AI billing service `services/C7E2-9256-1C43`;
- a fresh local console attestation that Google's Spend Cap toggle is enabled;
- current pinned price assumptions and local worst-case spend arithmetic;
- enough unused reservation capacity under the $5 pilot total.

Google's public Budget API does not expose every spend-cap field shown in the Cloud
Console, so the external spend-cap toggle is verified by a fresh console attestation
plus machine verification of the same budget's amount and scope. The exact hard stop
for this pilot is local: each authorized live run reserves $1 before its first Gemini
request, and cumulative reservations may never exceed $5. Reservations are not refunded
after failed or aborted runs.

The tracked policy intentionally contains placeholder project and billing IDs. Until
those are replaced and the isolated ADC/spend-cap evidence exists, preflight MUST fail.
