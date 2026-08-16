"""Driver-specific engine timeout controls."""

from __future__ import annotations

from unittest.mock import Mock

from sqlalchemy import Connection

from app.config import Settings
from app.db import apply_statement_timeout, build_connect_args


def test_sqlite_connect_args_do_not_receive_postgres_options() -> None:
    settings = Settings(_env_file=None, database_url="sqlite+pysqlite:///:memory:")

    assert build_connect_args(settings) == {"check_same_thread": False}


def test_postgres_connect_args_bound_connect_time_without_startup_options() -> None:
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

    assert connect_args == {"connect_timeout": 4}


def test_statement_timeout_is_applied_transaction_locally() -> None:
    connection = Mock(spec=Connection)

    apply_statement_timeout(connection, 9_000)

    connection.exec_driver_sql.assert_called_once_with("SET LOCAL statement_timeout = 9000")
