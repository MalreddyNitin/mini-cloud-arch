"""Tests for fail-closed production configuration."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings

PRODUCTION_DATABASE_URL = "postgresql://app:secret@example.neon.tech/app?sslmode=require"


def test_driver_neutral_postgres_urls_use_psycopg() -> None:
    settings = Settings(_env_file=None, database_url=PRODUCTION_DATABASE_URL)

    assert settings.database_dsn.startswith("postgresql+psycopg://")


def test_production_rejects_sqlite() -> None:
    with pytest.raises(ValidationError, match="production requires PostgreSQL"):
        Settings(_env_file=None, app_env="production", database_url="sqlite:///unsafe.db")


def test_production_rejects_non_postgres_database() -> None:
    with pytest.raises(ValidationError, match="production requires PostgreSQL"):
        Settings(_env_file=None, app_env="production", database_url="mysql://example/app")


def test_production_requires_ssl_for_runtime_and_direct_urls() -> None:
    insecure = "postgresql://app:secret@example.neon.tech/app"
    with pytest.raises(ValidationError, match="require sslmode"):
        Settings(_env_file=None, app_env="production", database_url=insecure)

    with pytest.raises(ValidationError, match="require sslmode"):
        Settings(
            _env_file=None,
            app_env="production",
            database_url=PRODUCTION_DATABASE_URL,
            database_url_direct=insecure,
        )


def test_production_writes_require_strong_key() -> None:
    with pytest.raises(ValidationError, match="at least 32 characters"):
        Settings(
            _env_file=None,
            app_env="production",
            database_url=PRODUCTION_DATABASE_URL,
            enable_writes=True,
            write_api_key="too-short",
        )


def test_production_read_only_needs_no_write_key() -> None:
    settings = Settings(
        _env_file=None,
        app_env="production",
        database_url=PRODUCTION_DATABASE_URL,
    )

    assert settings.enable_writes is False
    assert settings.write_api_key is None


def test_production_database_timeouts_fit_request_budget() -> None:
    settings = Settings(
        _env_file=None,
        app_env="production",
        database_url=PRODUCTION_DATABASE_URL,
    )

    assert settings.db_connect_timeout == 5
    assert settings.db_statement_timeout_ms == 10_000

    with pytest.raises(ValidationError, match="must not exceed 28000ms"):
        Settings(
            _env_file=None,
            app_env="production",
            database_url=PRODUCTION_DATABASE_URL,
            db_pool_timeout=10,
            db_connect_timeout=5,
            db_statement_timeout_ms=15_000,
        )


@pytest.mark.parametrize(
    ("field", "value"),
    (("db_connect_timeout", 11), ("db_statement_timeout_ms", 25_001)),
)
def test_database_timeout_fields_are_individually_bounded(field: str, value: int) -> None:
    with pytest.raises(ValidationError):
        Settings(_env_file=None, **{field: value})


def test_production_rejects_wildcard_cors() -> None:
    with pytest.raises(ValidationError, match="wildcard CORS"):
        Settings(
            _env_file=None,
            app_env="production",
            database_url=PRODUCTION_DATABASE_URL,
            cors_origins="*",
        )


def test_cors_accepts_comma_separated_and_json_values() -> None:
    comma = Settings(
        _env_file=None,
        cors_origins="https://one.example, https://two.example",
    )
    json_value = Settings(
        _env_file=None,
        cors_origins='["https://one.example", "https://two.example"]',
    )

    expected = ("https://one.example", "https://two.example")
    assert comma.cors_origin_list == expected
    assert json_value.cors_origin_list == expected


def test_partial_r2_configuration_is_rejected() -> None:
    with pytest.raises(ValidationError, match="must be set together"):
        Settings(_env_file=None, r2_bucket="configured-alone")
