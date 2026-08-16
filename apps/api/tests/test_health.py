"""Liveness, readiness, CORS, and response-hardening tests."""

from __future__ import annotations

from collections.abc import Iterator

from fastapi.testclient import TestClient
from sqlalchemy.exc import OperationalError

from app.db import get_session


def test_health_is_dependency_free_and_hardened(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Request-ID": "caller-request-123"})

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert response.headers["x-request-id"] == "caller-request-123"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["content-security-policy"].startswith("default-src 'none'")
    assert response.headers["cache-control"] == "no-store"


def test_invalid_request_id_is_replaced(client: TestClient) -> None:
    response = client.get("/health", headers={"X-Request-ID": "bad request id!"})

    assert response.status_code == 200
    assert response.headers["x-request-id"] != "bad request id!"
    assert len(response.headers["x-request-id"]) == 32


def test_ready_checks_database(client: TestClient) -> None:
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_ready_failure_is_controlled(app) -> None:
    class BrokenSession:
        def execute(self, _statement: object) -> None:
            raise OperationalError("SELECT 1", {}, RuntimeError("host details must stay hidden"))

    def broken_session() -> Iterator[BrokenSession]:
        yield BrokenSession()

    app.dependency_overrides[get_session] = broken_session
    with TestClient(app) as test_client:
        response = test_client.get("/ready")

    assert response.status_code == 503
    assert response.json() == {"detail": "database unavailable"}
    assert "host details" not in response.text


def test_cors_only_allows_configured_origin(client: TestClient) -> None:
    allowed = client.options(
        "/api/items",
        headers={
            "Origin": "http://localhost:5173",
            "Access-Control-Request-Method": "GET",
        },
    )
    denied = client.options(
        "/api/items",
        headers={
            "Origin": "https://untrusted.example",
            "Access-Control-Request-Method": "GET",
        },
    )

    assert allowed.status_code == 200
    assert allowed.headers["access-control-allow-origin"] == "http://localhost:5173"
    assert denied.status_code == 400
    assert "access-control-allow-origin" not in denied.headers


def test_unmatched_request_path_is_not_logged(client: TestClient, monkeypatch) -> None:
    records: list[dict[str, object]] = []

    def capture_log(_message: str, *, extra: dict[str, object]) -> None:
        records.append(extra)

    monkeypatch.setattr("app.middleware.logger.info", capture_log)
    sensitive_path = "/missing/private-filename-and-token"
    response = client.get(sensitive_path)

    assert response.status_code == 404
    assert records[-1]["path"] == "<unmatched>"
    assert sensitive_path not in str(records)
