"""Application configuration loaded exclusively from environment variables."""

from __future__ import annotations

import json
from functools import lru_cache
from typing import Annotated, Literal, Self
from urllib.parse import parse_qs, urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEFAULT_UPLOAD_CONTENT_TYPES = (
    "image/jpeg,image/png,image/webp,application/pdf,text/plain,text/csv,"
    "application/json,application/zip"
)
MAX_DB_REQUEST_BUDGET_MS = 28_000


def _split_setting(value: str) -> tuple[str, ...]:
    """Accept either a JSON string array or a comma-separated environment value."""

    stripped = value.strip()
    if not stripped:
        return ()
    if stripped.startswith("["):
        decoded = json.loads(stripped)
        if not isinstance(decoded, list) or not all(isinstance(item, str) for item in decoded):
            raise ValueError("must be a JSON string array or comma-separated string")
        return tuple(item.strip() for item in decoded if item.strip())
    return tuple(item.strip() for item in stripped.split(",") if item.strip())


def _validate_origin(origin: str) -> str:
    parsed = urlsplit(origin)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"invalid HTTP(S) origin: {origin!r}")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment or parsed.username:
        raise ValueError(
            f"origin must not contain credentials, a path, query, or fragment: {origin!r}"
        )
    return origin.rstrip("/")


class Settings(BaseSettings):
    """Typed runtime settings.

    Secret values use ``SecretStr`` so accidental model representations do not disclose
    credentials. Production refuses an enabled write surface without a strong token.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_env: Literal["development", "test", "production"] = "development"
    app_origin: str = "http://localhost:5173"
    cors_origins: str = ""
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    port: Annotated[int, Field(ge=1, le=65535)] = 8080

    database_url: SecretStr = SecretStr("sqlite+pysqlite:///./local.db")
    database_url_direct: SecretStr | None = None
    db_pool_size: Annotated[int, Field(ge=1, le=10)] = 2
    db_max_overflow: Annotated[int, Field(ge=0, le=10)] = 1
    db_pool_timeout: Annotated[int, Field(ge=1, le=60)] = 10
    db_pool_recycle: Annotated[int, Field(ge=30, le=3600)] = 300
    db_connect_timeout: Annotated[int, Field(ge=1, le=10)] = 5
    db_statement_timeout_ms: Annotated[int, Field(ge=100, le=25_000)] = 10_000

    r2_endpoint_url: str | None = None
    r2_access_key_id: SecretStr | None = None
    r2_secret_access_key: SecretStr | None = None
    r2_bucket: str | None = None
    r2_public_base_url: str | None = None

    max_upload_bytes: Annotated[int, Field(ge=1, le=100 * 1024 * 1024)] = 10 * 1024 * 1024
    allowed_upload_content_types: str = DEFAULT_UPLOAD_CONTENT_TYPES
    presign_expires_seconds: Annotated[int, Field(ge=60, le=900)] = 300
    max_page_size: Annotated[int, Field(ge=1, le=100)] = 100

    enable_writes: bool = False
    write_api_key: SecretStr | None = None

    @field_validator(
        "database_url_direct",
        "r2_endpoint_url",
        "r2_access_key_id",
        "r2_secret_access_key",
        "r2_bucket",
        "r2_public_base_url",
        "write_api_key",
        mode="before",
    )
    @classmethod
    def empty_string_is_none(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @field_validator("app_origin")
    @classmethod
    def validate_app_origin(cls, value: str) -> str:
        return _validate_origin(value)

    @field_validator("log_level", mode="before")
    @classmethod
    def normalize_log_level(cls, value: object) -> object:
        return value.upper() if isinstance(value, str) else value

    @model_validator(mode="after")
    def validate_runtime_contract(self) -> Self:
        origins = self.cors_origin_list
        if self.app_env == "production" and "*" in origins:
            raise ValueError("wildcard CORS is forbidden in production")

        r2_parts = (
            self.r2_endpoint_url,
            self.r2_access_key_id,
            self.r2_secret_access_key,
            self.r2_bucket,
        )
        has_any_r2_part = any(part is not None for part in r2_parts)
        has_all_r2_parts = all(part is not None for part in r2_parts)
        if has_any_r2_part and not has_all_r2_parts:
            raise ValueError(
                "R2_ENDPOINT_URL, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_BUCKET "
                "must be set together"
            )

        if self.r2_endpoint_url is not None:
            parsed = urlsplit(self.r2_endpoint_url)
            if parsed.scheme != "https" or not parsed.netloc:
                raise ValueError("R2_ENDPOINT_URL must be an HTTPS URL")

        if self.app_env == "production" and self.enable_writes:
            token = self.write_api_key.get_secret_value() if self.write_api_key else ""
            if len(token) < 32:
                raise ValueError(
                    "production writes require WRITE_API_KEY with at least 32 characters"
                )
        if self.app_env == "production":
            if not self.database_dsn.startswith("postgresql+psycopg://"):
                raise ValueError("production requires PostgreSQL with the psycopg driver")
            for dsn in {self.database_dsn, self.migration_dsn}:
                if dsn.startswith("postgresql") and not self._postgres_ssl_required(dsn):
                    raise ValueError(
                        "production PostgreSQL URLs require sslmode=require, verify-ca, "
                        "or verify-full"
                    )
            database_budget_ms = (
                self.db_pool_timeout + self.db_connect_timeout
            ) * 1000 + self.db_statement_timeout_ms
            if database_budget_ms > MAX_DB_REQUEST_BUDGET_MS:
                raise ValueError(
                    "DB_POOL_TIMEOUT + DB_CONNECT_TIMEOUT + DB_STATEMENT_TIMEOUT_MS "
                    f"must not exceed {MAX_DB_REQUEST_BUDGET_MS}ms in production"
                )
        return self

    @property
    def database_dsn(self) -> str:
        return self._normalize_postgres_driver(self.database_url.get_secret_value())

    @property
    def migration_dsn(self) -> str:
        value = self.database_url_direct or self.database_url
        return self._normalize_postgres_driver(value.get_secret_value())

    @staticmethod
    def _normalize_postgres_driver(value: str) -> str:
        """Use psycopg 3 when providers supply a driver-neutral PostgreSQL URL."""

        if value.startswith("postgres://"):
            return "postgresql+psycopg://" + value.removeprefix("postgres://")
        if value.startswith("postgresql://"):
            return "postgresql+psycopg://" + value.removeprefix("postgresql://")
        return value

    @staticmethod
    def _postgres_ssl_required(value: str) -> bool:
        query = parse_qs(urlsplit(value).query)
        ssl_modes = {mode.lower() for mode in query.get("sslmode", [])}
        return bool(ssl_modes & {"require", "verify-ca", "verify-full"})

    @property
    def cors_origin_list(self) -> tuple[str, ...]:
        configured = _split_setting(self.cors_origins)
        origins = configured or (self.app_origin,)
        return tuple(origin if origin == "*" else _validate_origin(origin) for origin in origins)

    @property
    def allowed_content_type_set(self) -> frozenset[str]:
        values = (value.lower() for value in _split_setting(self.allowed_upload_content_types))
        return frozenset(values)

    @property
    def r2_is_configured(self) -> bool:
        return all(
            value is not None
            for value in (
                self.r2_endpoint_url,
                self.r2_access_key_id,
                self.r2_secret_access_key,
                self.r2_bucket,
            )
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the process settings once; tests can inject settings through ``create_app``."""

    return Settings()
