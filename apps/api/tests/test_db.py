"""Driver-specific engine timeout controls."""

from __future__ import annotations

from app.config import Settings
from app.db import build_connect_args


def test_sqlite_connect_args_do_not_receive_postgres_options() -> None:
    settings = Settings(_env_file=None, database_url="sqlite+pysqlite:///:memory:")

    assert build_connect_args(settings) == {"check_same_thread": False}


def test_postgres_connect_args_bound_connect_and_statement_time() -> None:
    settings = Settings(
        _env_file=None,
        database_url=(
            "postgresql://app:secret@example.neon.tech/app?sslmode=require&"
            "options=-c%20idle_in_transaction_session_timeout%3D5000"
        ),
        db_connect_timeout=4,
        db_statement_timeout_ms=9_000,
    )

    connect_args = build_connect_args(settings)

    assert connect_args["connect_timeout"] == 4
    assert connect_args["options"] == (
        "-c idle_in_transaction_session_timeout=5000 -c statement_timeout=9000"
    )
