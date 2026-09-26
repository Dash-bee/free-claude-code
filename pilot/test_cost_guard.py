from pathlib import Path

import pytest

from pilot.cost_guard import AttemptRecord, BudgetExceeded, SpendGuard


def _record(task_id: str, cost: float) -> AttemptRecord:
    return AttemptRecord(
        task_id=task_id,
        provider="provider-a",
        model="model-a",
        estimated_cost_usd=cost,
        success=True,
        latency_s=0.25,
        fallback_index=0,
    )


def test_total_budget_is_hard_stop() -> None:
    guard = SpendGuard(total_cap_usd=0.50, per_task_cap_usd=0.50)
    guard.record(_record("t1", 0.30))
    with pytest.raises(BudgetExceeded):
        guard.authorize("t2", 0.21)


def test_per_task_budget_is_hard_stop() -> None:
    guard = SpendGuard(total_cap_usd=5.0, per_task_cap_usd=0.25)
    guard.record(_record("t1", 0.20))
    with pytest.raises(BudgetExceeded):
        guard.authorize("t1", 0.06)


def test_ledger_is_complete_and_serializable(tmp_path: Path) -> None:
    guard = SpendGuard(total_cap_usd=5.0, per_task_cap_usd=0.25)
    guard.record(_record("t1", 0.10))
    guard.record(_record("t2", 0.12))
    ledger = tmp_path / "attempts.jsonl"
    guard.write_jsonl(ledger)
    lines = ledger.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert guard.total_spent == pytest.approx(0.22)
