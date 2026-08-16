"""Integration tests for bounded item CRUD and write authorization."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from app.db import Base, build_engine
from app.main import create_app
from tests.conftest import make_settings


def test_item_crud_and_pagination(client: TestClient) -> None:
    assert client.get("/api/items").json() == {
        "items": [],
        "total": 0,
        "limit": 20,
        "offset": 0,
    }

    first = client.post("/api/items", json={"name": "  first  "})
    second = client.post("/api/items", json={"name": "second"})
    assert first.status_code == 201
    assert first.json()["name"] == "first"
    assert second.status_code == 201

    page = client.get("/api/items", params={"limit": 1, "offset": 0})
    assert page.status_code == 200
    assert page.json()["total"] == 2
    assert page.json()["limit"] == 1
    assert len(page.json()["items"]) == 1

    item_id = first.json()["id"]
    updated = client.patch(f"/api/items/{item_id}", json={"name": "renamed"})
    assert updated.status_code == 200
    assert updated.json()["name"] == "renamed"
    assert updated.json()["created_at"] == first.json()["created_at"]

    deleted = client.delete(f"/api/items/{item_id}")
    assert deleted.status_code == 204
    assert deleted.content == b""
    assert client.patch(f"/api/items/{item_id}", json={"name": "gone"}).status_code == 404
    assert client.delete(f"/api/items/{item_id}").status_code == 404


def test_item_input_and_query_bounds(client: TestClient) -> None:
    assert client.post("/api/items", json={"name": "   "}).status_code == 422
    assert client.post("/api/items", json={"name": "x" * 121}).status_code == 422
    assert client.post("/api/items", json={"name": "ok", "extra": True}).status_code == 422
    assert client.get("/api/items", params={"limit": 101}).status_code == 422
    assert client.get("/api/items", params={"offset": 10_001}).status_code == 422


def test_configured_max_page_size_is_enforced(tmp_path: Path) -> None:
    settings = make_settings(tmp_path / "small-page.db", max_page_size=5)
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        response = client.get("/api/items", params={"limit": 6})

    assert response.status_code == 422
    assert response.json() == {"detail": "limit must not exceed 5"}


def test_writes_are_disabled_by_default(tmp_path: Path) -> None:
    settings = make_settings(tmp_path / "readonly.db", enable_writes=False)
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        assert client.get("/api/items").status_code == 200
        response = client.post("/api/items", json={"name": "blocked"})

    assert response.status_code == 403
    assert response.json() == {"detail": "write operations are disabled"}


def test_bearer_token_protects_enabled_writes(tmp_path: Path) -> None:
    token = "test-token-that-is-long-enough-for-production"
    settings = make_settings(tmp_path / "protected.db", write_api_key=token)
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        missing = client.post("/api/items", json={"name": "missing"})
        wrong = client.post(
            "/api/items",
            json={"name": "wrong"},
            headers={"Authorization": "Bearer wrong"},
        )
        accepted = client.post(
            "/api/items",
            json={"name": "accepted"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert missing.status_code == 401
    assert missing.headers["www-authenticate"] == "Bearer"
    assert wrong.status_code == 401
    assert accepted.status_code == 201


def test_bad_item_uuid_is_validation_error(client: TestClient) -> None:
    response = client.patch("/api/items/not-a-uuid", json={"name": "anything"})

    assert response.status_code == 422
