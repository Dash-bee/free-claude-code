"""Hard spend guard for the live FCC pilot."""

from dataclasses import asdict, dataclass
import json
from pathlib import Path


class BudgetExceeded(RuntimeError):
    pass


@dataclass(frozen=True)
class AttemptRecord:
    task_id: str
    provider: str
    model: str
    estimated_cost_usd: float
    success: bool
    latency_s: float
    fallback_index: int
    error_class: str | None = None


class SpendGuard:
    def __init__(self, *, total_cap_usd: float, per_task_cap_usd: float) -> None:
        self.total_cap = total_cap_usd
        self.per_task_cap = per_task_cap_usd
        self.total_spent = 0.0
        self.task_spend: dict[str, float] = {}
        self.records: list[AttemptRecord] = []
    def authorize(self, task_id: str, projected_cost_usd: float) -> None:
        if projected_cost_usd < 0:
            raise ValueError("projected cost must be non-negative")
        task_after = self.task_spend.get(task_id, 0.0) + projected_cost_usd
        total_after = self.total_spent + projected_cost_usd
        if task_after > self.per_task_cap:
            raise BudgetExceeded(
                f"task {task_id} would exceed dollar {self.per_task_cap:.2f} cap"
            )
        if total_after > self.total_cap:
            raise BudgetExceeded(
                f"pilot would exceed dollar {self.total_cap:.2f} total cap"
            )

    def record(self, record: AttemptRecord) -> None:
        self.authorize(record.task_id, record.estimated_cost_usd)
        self.total_spent += record.estimated_cost_usd
        self.task_spend[record.task_id] = (
            self.task_spend.get(record.task_id, 0.0)
            + record.estimated_cost_usd
        )
        self.records.append(record)

    def write_jsonl(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            for record in self.records:
                handle.write(json.dumps(asdict(record), sort_keys=True) + "\n")
