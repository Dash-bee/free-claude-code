# Karp FCC Pilot Contract

## Purpose
Qualify FCC as a commodity/overflow model-routing layer before any production worker may depend on it.
This pilot evaluates routing reliability, not whether any one model is “smart enough.”

## Immutable pin
- Upstream: Alishahryar1/free-claude-code
- Upstream commit: `ba4b934147855025df30bbca3ad6d436158fe671`
- Fork: `Dash-bee/free-claude-code`
- Pilot branch: `karp/fcc-pilot-v1`
- Python: 3.14.7
- No upstream auto-update during qualification.

## Isolation boundary
The pilot may write only inside the disposable pilot workspace.
Do not point workers at Founder City, SILO, Shout Out, Human Flourishing, household, or school repositories.
Use an isolated HOME/USERPROFILE for FCC and harness configuration.
Do not commit credentials. Live-provider secrets are injected at process launch only.
Deterministic tests use mock/controlled providers and require no paid credentials.
All worker changes are disposable until a gate explicitly promotes them.

## Gate 0 — Supply chain
PASS requires the checked-out Git SHA to equal the immutable pin, a clean tracked tree before tests,
the license to remain AGPL-3.0-only, and the environment report to record Python and FCC versions.
Any mismatch is a hard stop.
## Gate 1 — Deterministic fault injection
Run without live provider credentials.

Required scenarios:
1. Primary provider unavailable before output; ordered fallback succeeds.
2. Primary returns normalized malformed/protocol failure before output; fallback succeeds.
3. Primary emits any assistant frame and then fails; fallback MUST NOT start.
4. Primary returns 429/quota failure; retries remain bounded and fallback eventually succeeds.
5. Retry-After is honored without a retry storm.
6. Primary is slow; latency measurements capture time-to-first-byte and end-to-end duration.
7. All candidates fail; FCC returns the final typed error and terminates cleanly.
8. Repeated requests do not leak provider/session state across tasks.

PASS:
- 100% of deterministic assertions pass.
- Zero duplicate assistant lifecycles.
- Zero fallback after first emitted assistant frame.
- Zero unbounded retries or hangs.
- Every process exits or is reaped after timeout.

## Gate 2 — Live canary
Use low-risk provider accounts/models only and the disposable fixture repository.
Start with two providers, then add a third only after the two-provider path passes.
Run 25 small tasks per route: read-only inspection, tiny code edits, unit tests, and documentation edits.
No deploys, merges, purchases, messaging, credential changes, or production data access.

Record per attempt: provider, model, task ID, outcome, retry count, fallback count,
TTFB, total latency, input/output tokens when available, estimated cost, and terminal error class.
## Gate 3 — Cost and quota
Cost is a routing constraint, not an after-the-fact report.

Hard limits:
- Pilot spend cap: USD 5 total unless explicitly raised.
- Per-task estimated cap: USD 0.25.
- A task that would exceed a cap must stop before opening another paid attempt.
- Free-tier exhaustion must be treated as capacity loss, not as permission to spend elsewhere.

PASS:
- 100% of paid attempts appear in the ledger.
- No task exceeds the configured cap.
- Quota exhaustion produces bounded retries/fallback or a clean terminal failure.
- Cost per successful task and fallback-induced cost are reportable.

## Gate 4 — Unattended worker soak
Run at least 100 fixture-repository tasks with no human intervention.
Every task has a machine-verifiable success condition (tests, expected file diff, or read-only assertion).
Set a hard wall-clock timeout per task and a global stop condition.

Automatic stop conditions:
- any write outside the disposable workspace;
- any credential or secret appears in logs/artifacts;
- spend cap reached;
- three consecutive infrastructure failures;
- rolling infrastructure failure rate above 5% over the last 20 tasks;
- orphaned child process survives cleanup;
- one task exceeds the hard timeout twice.

PASS:
- at least 98% infrastructure completion;
- zero workspace-boundary violations;
- zero orphaned worker processes;
- zero false “success” when the verification step fails;
- p95 latency and cost are recorded, not guessed.
## Gate 5 — Shadow production
Replay 20 representative low-risk worker jobs against copies of real repositories.
FCC output remains scratch-only and is compared with the current trusted path.
No automatic merge or propagation.

Promotion rule:
FCC may enter production only for worker classes that passed all prior gates.
Promotion is per worker class and provider route, never blanket approval.

Initial production authority:
- allowed: search, summarize, boilerplate, tests, lint/fix, docs, disposable refactors;
- review required: substantive code changes and repository commits;
- prohibited initially: architecture canon, security-sensitive changes, secrets, deployments,
  purchases, external messages, destructive operations, and final quality approval.

## Evidence package
Each run writes a timestamped result directory containing:
- manifest with pinned SHA and environment;
- scenario results;
- JSONL attempt ledger;
- latency/cost summary;
- failed-task artifacts;
- final PASS / FAIL / BLOCKED verdict with exact failed gates.

A PASS is evidence for the pinned commit only. Updating FCC invalidates the qualification until the
fault suite and abbreviated live canary are rerun.

### Vertex-specific preflight
Before any Vertex/Gemini generation request, the live launcher MUST obtain a fresh PASS
from `vertex_preflight.ps1`. A failure is a hard stop, not a warning.

The PASS binds the run to one exact project, one exact open billing account, one exact
Vertex API service, the tracked model/location allowlists, the isolated ADC path, a
machine-verified project/service budget, a fresh Spend Cap console attestation, and the
tracked local dollar envelope. The run reservation is written before inference starts.
Direct Vertex/Gemini invocation that bypasses this launcher is outside the authorized pilot.
