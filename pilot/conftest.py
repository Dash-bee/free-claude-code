"""Pilot-only guardrails."""

import ipaddress
import socket

import pytest


def _loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@pytest.fixture(autouse=True)
def block_external_network(monkeypatch: pytest.MonkeyPatch) -> None:
    original = socket.socket.connect

    def guarded_connect(sock: socket.socket, address) -> object:
        if isinstance(address, tuple) and address:
            host = str(address[0])
            if not _loopback(host):
                raise RuntimeError(
                    f"FCC pilot blocked external network connection to {host}"
                )
        return original(sock, address)

    monkeypatch.setattr(socket.socket, "connect", guarded_connect)
