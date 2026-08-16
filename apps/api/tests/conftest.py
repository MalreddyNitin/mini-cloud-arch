"""Cloud-free API fixtures using SQLite and an in-memory presign fake."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.db import Base, build_engine
from app.main import create_app
from app.services.storage import R2Storage


class FakePresignClient:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def generate_presigned_url(
        self,
        client_method: str,
        Params: dict[str, Any],
        ExpiresIn: int,
        HttpMethod: str,
    ) -> str:
        self.calls.append(
            {
                "client_method": client_method,
                "params": Params,
                "expires_in": ExpiresIn,
                "http_method": HttpMethod,
            }
        )
        key = Params["Key"]
        return f"https://signed.invalid/{key}?signature=redacted"


def make_settings(database_path: Path, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "_env_file": None,
        "app_env": "test",
        "app_origin": "http://localhost:5173",
        "database_url": f"sqlite+pysqlite:///{database_path.as_posix()}",
        "enable_writes": True,
        "r2_endpoint_url": "https://account.r2.cloudflarestorage.com",
        "r2_access_key_id": "test-access-key",
        "r2_secret_access_key": "test-secret-key",
        "r2_bucket": "test-private-bucket",
    }
    values.update(overrides)
    return Settings(**values)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return make_settings(tmp_path / "test.db")


@pytest.fixture
def presign_client() -> FakePresignClient:
    return FakePresignClient()


@pytest.fixture
def app(settings: Settings, presign_client: FakePresignClient):
    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    storage = R2Storage(settings, client=presign_client)
    return create_app(settings, engine=engine, storage=storage)


@pytest.fixture
def client(app) -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client
