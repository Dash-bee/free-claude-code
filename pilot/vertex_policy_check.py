"""Fail-closed local policy validation for the Vertex ADC pilot."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any


class PolicyError(RuntimeError):
    pass


@dataclass(frozen=True)
class CostEnvelope:
    worst_request_usd: Decimal
    worst_run_usd: Decimal


def load_policy(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _money(value: object) -> Decimal:
    return Decimal(str(value))


def validate_policy(policy: dict[str, Any], *, today: date | None = None) -> CostEnvelope:
    today = today or datetime.now(UTC).date()
    if policy.get("schema_version") != 1:
        raise PolicyError("unsupported policy schema")
    project = str(policy.get("expected_project_id", ""))
    billing = str(policy.get("expected_billing_account_id", ""))
    if not project or project.startswith("SET_ME_"):
        raise PolicyError("expected_project_id is not configured")
    if not billing or billing.startswith("SET_ME_"):
        raise PolicyError("expected_billing_account_id is not configured")

    selected_model = str(policy.get("selected_model", ""))
    allow_models = set(policy.get("allowed_models") or [])
    if selected_model not in allow_models:
        raise PolicyError("selected Vertex model is not allowlisted")
    if not selected_model.startswith("vertex/google/"):
        raise PolicyError("selected model is not a Vertex Google model")

    location = str(policy.get("selected_location", ""))
    allow_locations = set(policy.get("allowed_locations") or [])
    if location not in allow_locations:
        raise PolicyError("selected Vertex location is not allowlisted")

    pricing = policy["pricing_guard"]
    valid_until = date.fromisoformat(str(pricing["valid_until"]))
    if today > valid_until:
        raise PolicyError("pricing guard is stale; revalidate public pricing")
    if pricing.get("currency") != "USD":
        raise PolicyError("pricing guard currency must be USD")

    caps = policy["local_caps"]
    input_tokens = _money(caps["max_input_tokens_per_request"])
    output_tokens = _money(caps["max_output_tokens_per_request"])
    input_rate = _money(pricing["input_per_million_usd"])
    output_rate = _money(pricing["output_per_million_usd"])
    worst_request = (
        input_tokens * input_rate / Decimal("1000000")
        + output_tokens * output_rate / Decimal("1000000")
    )
    worst_run = worst_request * _money(caps["max_requests_per_run"])

    per_task = _money(caps["per_task_usd"])
    run_reservation = _money(caps["run_reservation_usd"])
    pilot_total = _money(caps["pilot_total_usd"])
    google_cap = _money(policy["google_budget"]["max_amount_usd"])

    if worst_request > per_task:
        raise PolicyError("worst-case request exceeds per-task hard cap")
    if worst_run > run_reservation:
        raise PolicyError("worst-case run exceeds reserved run hard cap")
    if run_reservation > pilot_total:
        raise PolicyError("run reservation exceeds pilot total hard cap")
    if google_cap > pilot_total:
        raise PolicyError("Google spend-cap amount exceeds local pilot hard cap")

    if policy.get("required_api") != "aiplatform.googleapis.com":
        raise PolicyError("required API must be aiplatform.googleapis.com")
    if not policy.get("required_project_label_key"):
        raise PolicyError("dedicated project label key is required")
    if not policy.get("required_project_label_value"):
        raise PolicyError("dedicated project label value is required")

    return CostEnvelope(worst_request, worst_run)


def money_to_decimal(value: dict[str, Any]) -> Decimal:
    units = Decimal(str(value.get("units", "0")))
    nanos = Decimal(str(value.get("nanos", 0))) / Decimal("1000000000")
    return units + nanos
def verify_budget(
    budget: dict[str, Any],
    *,
    policy: dict[str, Any],
    project_id: str,
    project_number: str,
) -> None:
    expected = policy["google_budget"]
    if budget.get("displayName") != expected["display_name"]:
        raise PolicyError("budget display name mismatch")

    amount = budget.get("amount", {}).get("specifiedAmount")
    if not isinstance(amount, dict):
        raise PolicyError("budget must use a specified amount")
    if amount.get("currencyCode") != "USD":
        raise PolicyError("budget currency must be USD")
    if money_to_decimal(amount) > _money(expected["max_amount_usd"]):
        raise PolicyError("budget amount exceeds allowed Google cap")

    filt = budget.get("budgetFilter") or {}
    projects = set(filt.get("projects") or [])
    expected_projects = {f"projects/{project_id}", f"projects/{project_number}"}
    if len(projects) != 1 or not projects.intersection(expected_projects):
        raise PolicyError("budget is not scoped only to the FCC pilot project")

    services = set(filt.get("services") or [])
    if services != {expected["service_resource"]}:
        raise PolicyError("budget is not scoped only to the Vertex AI billing service")
    if filt.get("calendarPeriod") != expected["calendar_period"]:
        raise PolicyError("budget calendar period mismatch")
def verify_attestation(
    attestation: dict[str, Any],
    *,
    policy: dict[str, Any],
    now: datetime | None = None,
) -> None:
    now = now or datetime.now(UTC)
    budget = policy["google_budget"]
    if attestation.get("project_id") != policy["expected_project_id"]:
        raise PolicyError("spend-cap attestation project mismatch")
    if attestation.get("billing_account_id") != policy["expected_billing_account_id"]:
        raise PolicyError("spend-cap attestation billing account mismatch")
    if attestation.get("budget_display_name") != budget["display_name"]:
        raise PolicyError("spend-cap attestation budget mismatch")
    if _money(attestation.get("budget_amount_usd")) > _money(budget["max_amount_usd"]):
        raise PolicyError("attested spend cap exceeds policy")
    if attestation.get("service_resource") != budget["service_resource"]:
        raise PolicyError("spend-cap attestation service mismatch")
    if attestation.get("spend_cap_enabled") is not True:
        raise PolicyError("Google spend-cap toggle is not attested as enabled")

    stamp = datetime.fromisoformat(str(attestation["confirmed_at_utc"]).replace("Z", "+00:00"))
    age_h = (now - stamp.astimezone(UTC)).total_seconds() / 3600
    if age_h < 0 or age_h > float(budget["spend_cap_attestation_max_age_hours"]):
        raise PolicyError("spend-cap attestation is stale")


def main() -> int:
    path = Path(__file__).with_name("vertex_preflight_policy.json")
    try:
        envelope = validate_policy(load_policy(path))
    except (PolicyError, KeyError, ValueError) as exc:
        print(f"POLICY=FAIL {exc}")
        return 2
    print(f"POLICY=PASS worst_request_usd={envelope.worst_request_usd:.6f} "
          f"worst_run_usd={envelope.worst_run_usd:.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
