"""R2 abstraction and file-route security tests with no network calls."""

from __future__ import annotations

import re
from datetime import UTC, datetime
from pathlib import Path

from fastapi.testclient import TestClient

from app.db import Base, build_engine
from app.main import create_app
from app.services.storage import (
    R2Storage,
    make_upload_key,
    sanitize_filename,
    validate_download_key,
)
from tests.conftest import FakePresignClient, make_settings


def test_filename_is_reduced_to_safe_basename() -> None:
    assert sanitize_filename("../../Quarterly résumé (final).PDF") == "Quarterly-resume-final-.PDF"
    assert sanitize_filename("..\\..\\.env") == "env"
    assert sanitize_filename("💥") == "file"
    assert len(sanitize_filename("a" * 200 + ".txt")) == 80


def test_generated_key_is_server_owned_and_download_validation_is_strict() -> None:
    key = make_upload_key("../../report.pdf", now=datetime(2026, 8, 15, tzinfo=UTC))

    assert re.fullmatch(r"uploads/public/2026/08/[0-9a-f]{32}-report\.pdf", key)
    assert validate_download_key(key) == key
    for unsafe in (
        "report.pdf",
        "uploads/../secret",
        "uploads/private/2026/08/" + "a" * 32 + "-secret.txt",
        "uploads/public/2026/08/not-a-generated-key.txt",
    ):
        try:
            validate_download_key(unsafe)
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe key accepted: {unsafe}")


def test_upload_presign_enforces_type_size_and_signed_headers(settings) -> None:
    fake = FakePresignClient()
    storage = R2Storage(settings, client=fake)

    url, key, headers = storage.presign_upload(
        filename="photo.png",
        content_type="image/png",
        size_bytes=1024,
    )

    assert url.startswith("https://signed.invalid/uploads/public/")
    assert headers == {"Content-Type": "image/png"}
    assert fake.calls[0]["client_method"] == "put_object"
    assert fake.calls[0]["http_method"] == "PUT"
    assert fake.calls[0]["params"] == {
        "Bucket": "test-private-bucket",
        "Key": key,
        "ContentType": "image/png",
        "ContentLength": 1024,
    }

    for invalid in (
        {"content_type": "text/html", "size_bytes": 1},
        {"content_type": "image/png", "size_bytes": 0},
        {"content_type": "image/png", "size_bytes": settings.max_upload_bytes + 1},
    ):
        try:
            storage.presign_upload(filename="file", **invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid upload accepted: {invalid}")


def test_presign_routes_return_direct_transfer_contract(
    client: TestClient,
    presign_client: FakePresignClient,
    monkeypatch,
) -> None:
    records: list[dict[str, object]] = []

    def capture_log(_message: str, *, extra: dict[str, object]) -> None:
        records.append(extra)

    monkeypatch.setattr("app.middleware.logger.info", capture_log)
    upload = client.post(
        "/api/files/presign-upload",
        json={
            "filename": "photo.png",
            "content_type": "image/png; charset=binary",
            "size_bytes": 4096,
        },
    )

    payload = upload.json()
    download = client.get(f"/api/files/{payload['key']}/presign-download")

    assert upload.status_code == 200
    assert payload["method"] == "PUT"
    assert payload["headers"] == {"Content-Type": "image/png"}
    assert payload["expires_in"] == 300
    assert "upload_url" in payload and "key" in payload
    assert presign_client.calls[-1]["params"]["Key"] == payload["key"]

    assert download.status_code == 200
    assert download.json()["key"] == payload["key"]
    assert download.json()["expires_in"] == 300
    assert presign_client.calls[-1]["client_method"] == "get_object"

    logged_paths = [record["path"] for record in records]
    assert payload["key"] not in logged_paths
    assert "/api/files/{key:path}/presign-download" in logged_paths


def test_presign_routes_reject_abuse(client: TestClient, settings) -> None:
    oversized = client.post(
        "/api/files/presign-upload",
        json={
            "filename": "large.zip",
            "content_type": "application/zip",
            "size_bytes": settings.max_upload_bytes + 1,
        },
    )
    html = client.post(
        "/api/files/presign-upload",
        json={"filename": "x.html", "content_type": "text/html", "size_bytes": 100},
    )
    traversal = client.get("/api/files/uploads/../secret/presign-download")

    assert oversized.status_code == 422
    assert html.status_code == 422
    assert traversal.status_code in {404, 422}


def test_unconfigured_storage_returns_controlled_503(tmp_path: Path) -> None:
    settings = make_settings(
        tmp_path / "no-r2.db",
        r2_endpoint_url=None,
        r2_access_key_id=None,
        r2_secret_access_key=None,
        r2_bucket=None,
    )
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        response = client.post(
            "/api/files/presign-upload",
            json={"filename": "x.txt", "content_type": "text/plain", "size_bytes": 10},
        )

    assert response.status_code == 503
    assert response.json() == {"detail": "object storage is unavailable"}


def test_presign_endpoints_obey_write_gate(tmp_path: Path) -> None:
    settings = make_settings(tmp_path / "disabled.db", enable_writes=False)
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        response = client.post(
            "/api/files/presign-upload",
            json={"filename": "x.txt", "content_type": "text/plain", "size_bytes": 10},
        )

    assert response.status_code == 403
