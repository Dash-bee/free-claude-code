"""Karp FCC deterministic qualification tests.

These tests exercise the real FCC API/fallback layer with controlled provider boundaries.
They make no live provider calls and must stay safe to run unattended.
"""

import asyncio
import time
from collections.abc import AsyncIterator

from free_claude_code.core.anthropic import MessagesRequest
from free_claude_code.core.failures import ExecutionFailure, FailureKind
from free_claude_code.core.reasoning import ReasoningPolicy
from tests.api.model_fallback_support import (
    ControlledFallbackProvider,
    execution_failure,
    fallback_client,
    messages_payload,
    text_stream,
)


def _failure(kind: FailureKind, status: int, message: str) -> ExecutionFailure:
    return ExecutionFailure(
        kind=kind,
        status_code=status,
        message=message,
        retryable=True,
    )
def test_provider_failover_before_output() -> None:
    primary = ControlledFallbackProvider(failure=execution_failure("primary unavailable"))
    fallback = ControlledFallbackProvider(text="fallback-ok")
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    assert response.status_code == 200
    assert "fallback-ok" in response.text
    assert primary.close_calls == fallback.close_calls == 1


def test_malformed_protocol_failure_falls_back_before_output() -> None:
    primary = ControlledFallbackProvider(
        failure=_failure(
            FailureKind.UPSTREAM,
            502,
            "malformed upstream protocol response",
        )
    )
    fallback = ControlledFallbackProvider(text="contained-and-recovered")
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    assert response.status_code == 200
    assert "contained-and-recovered" in response.text
    assert "malformed upstream" not in response.text


def test_quota_exhaustion_falls_back_cleanly() -> None:
    primary = ControlledFallbackProvider(
        failure=_failure(FailureKind.RATE_LIMIT, 429, "quota exhausted")
    )
    fallback = ControlledFallbackProvider(text="quota-fallback-ok")
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    assert response.status_code == 200
    assert "quota-fallback-ok" in response.text
    assert "quota exhausted" not in response.text
def test_postframe_failure_never_opens_fallback() -> None:
    first_frame = text_stream("partial", model="nvidia_nim/primary-model")[0]
    primary = ControlledFallbackProvider(
        chunks_before_failure=(first_frame,),
        failure=execution_failure("failed after output began"),
    )
    fallback = ControlledFallbackProvider(text="must-not-run")
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    assert response.status_code == 200
    assert fallback.stream_models == []
    assert "must-not-run" not in response.text


class SlowProvider(ControlledFallbackProvider):
    def __init__(self, *, delay_s: float, text: str) -> None:
        super().__init__(text=text)
        self.delay_s = delay_s

    async def stream_messages(
        self,
        request: MessagesRequest,
        input_tokens: int = 0,
        *,
        request_id: str | None = None,
        response_model: str | None = None,
        reasoning: ReasoningPolicy,
        request_headers=None,
        model_info=None,
    ) -> AsyncIterator[str]:
        await asyncio.sleep(self.delay_s)
        async for chunk in super().stream_messages(
            request,
            input_tokens,
            request_id=request_id,
            response_model=response_model,
            reasoning=reasoning,
            request_headers=request_headers,
            model_info=model_info,
        ):
            yield chunk
def test_latency_is_measurable_and_bounded() -> None:
    primary = SlowProvider(delay_s=0.05, text="slow-ok")
    fallback = ControlledFallbackProvider(text="unused")
    started = time.perf_counter()
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    elapsed = time.perf_counter() - started
    assert response.status_code == 200
    assert "slow-ok" in response.text
    assert elapsed >= 0.04
    assert elapsed < 2.0


def test_repeated_unattended_requests_do_not_leak_route_state() -> None:
    primary = ControlledFallbackProvider(failure=execution_failure("planned outage"))
    fallback = ControlledFallbackProvider(text="worker-ok")
    with fallback_client(primary, fallback) as client:
        for task_id in range(100):
            response = client.post("/v1/messages", json=messages_payload(stream=True))
            assert response.status_code == 200, task_id
            assert "worker-ok" in response.text, task_id
    assert len(primary.stream_models) == 100
    assert len(fallback.stream_models) == 100
    assert primary.close_calls == 100
    assert fallback.close_calls == 100


def test_all_candidates_fail_with_final_typed_error() -> None:
    primary = ControlledFallbackProvider(failure=execution_failure("primary down"))
    fallback = ControlledFallbackProvider(
        failure=_failure(FailureKind.RATE_LIMIT, 429, "fallback quota exhausted")
    )
    with fallback_client(primary, fallback) as client:
        response = client.post("/v1/messages", json=messages_payload(stream=True))
    assert response.status_code == 429
    assert response.json()["error"]["type"] == "rate_limit_error"
    assert response.headers["x-should-retry"] == "false"
