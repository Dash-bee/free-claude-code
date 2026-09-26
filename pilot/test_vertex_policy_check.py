from copy import deepcopy
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import pytest

from pilot.vertex_policy_check import (
    PolicyError,
    load_policy,
    validate_policy,
    verify_attestation,
    verify_budget,
)


def _policy() -> dict:
    policy = load_policy(Path(__file__).with_name("vertex_preflight_policy.json"))
    policy = deepcopy(policy)
    policy["expected_project_id"] = "fcc-pilot-test"
    policy["expected_billing_account_id"] = "ABCDEF-123456-ABCDEF"
    return policy


def test_valid_policy_has_bounded_cost_envelope() -> None:
    envelope = validate_policy(_policy(), today=date(2026, 9, 26))
    assert envelope.worst_request_usd == Decimal("0.034608")
    assert envelope.worst_run_usd == Decimal("0.865200")
def test_policy_rejects_placeholder_identity() -> None:
    policy = _policy()
    policy["expected_project_id"] = "SET_ME_PROJECT"
    with pytest.raises(PolicyError, match="project"):
        validate_policy(policy, today=date(2026, 9, 26))


def test_policy_rejects_stale_pricing() -> None:
    with pytest.raises(PolicyError, match="stale"):
        validate_policy(_policy(), today=date(2026, 10, 27))


def test_policy_rejects_unallowlisted_model() -> None:
    policy = _policy()
    policy["selected_model"] = "vertex/google/expensive-unreviewed-model"
    with pytest.raises(PolicyError, match="allowlisted"):
        validate_policy(policy, today=date(2026, 9, 26))


def _budget() -> dict:
    return {
        "displayName": "FCC Pilot Vertex Spend Cap",
        "amount": {
            "specifiedAmount": {
                "currencyCode": "USD",
                "units": "5",
                "nanos": 0,
            }
        },
        "budgetFilter": {
            "projects": ["projects/123456789"],
            "services": ["services/C7E2-9256-1C43"],
            "calendarPeriod": "MONTH",
        },
    }
def test_budget_must_be_project_and_vertex_only() -> None:
    policy = _policy()
    verify_budget(
        _budget(),
        policy=policy,
        project_id="fcc-pilot-test",
        project_number="123456789",
    )

    bad = _budget()
    bad["budgetFilter"]["services"].append("services/OTHER")
    with pytest.raises(PolicyError, match="Vertex AI"):
        verify_budget(
            bad,
            policy=policy,
            project_id="fcc-pilot-test",
            project_number="123456789",
        )


def test_spend_cap_attestation_must_be_fresh_and_exact() -> None:
    policy = _policy()
    now = datetime(2026, 9, 26, 12, tzinfo=UTC)
    attestation = {
        "project_id": "fcc-pilot-test",
        "billing_account_id": "ABCDEF-123456-ABCDEF",
        "budget_display_name": "FCC Pilot Vertex Spend Cap",
        "budget_amount_usd": 5.0,
        "service_resource": "services/C7E2-9256-1C43",
        "spend_cap_enabled": True,
        "confirmed_at_utc": (now - timedelta(hours=1)).isoformat(),
    }
    verify_attestation(attestation, policy=policy, now=now)

    stale = dict(attestation)
    stale["confirmed_at_utc"] = (now - timedelta(days=8)).isoformat()
    with pytest.raises(PolicyError, match="stale"):
        verify_attestation(stale, policy=policy, now=now)
