"""SQLAlchemy engine, session, and FastAPI dependency helpers."""

from __future__ import annotations

from collections.abc import Generator
from typing import Any

from fastapi import Request
from sqlalchemy import Connection, Engine, create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import Settings


class Base(DeclarativeBase):
    """Declarative model base used by both the application and Alembic."""


SessionFactory = sessionmaker[Session]


def build_connect_args(settings: Settings) -> dict[str, Any]:
    """Return driver-specific connection controls without leaking them into SQLite."""

    database_url = settings.database_dsn
    if database_url.startswith("sqlite"):
        return {"check_same_thread": False}
    if not database_url.startswith("postgresql"):
        return {}

    return {"connect_timeout": settings.db_connect_timeout}


def apply_statement_timeout(connection: Connection, timeout_ms: int) -> None:
    """Bound each PostgreSQL transaction without pooler-incompatible startup options."""

    connection.exec_driver_sql(f"SET LOCAL statement_timeout = {timeout_ms}")


def build_engine(settings: Settings) -> Engine:
    """Build a bounded engine suitable for one small serverless container."""

    database_url = settings.database_dsn
    common: dict[str, Any] = {
        "pool_pre_ping": True,
        "future": True,
        "connect_args": build_connect_args(settings),
    }

    if database_url.startswith("sqlite"):
        if database_url in {"sqlite://", "sqlite:///:memory:", "sqlite+pysqlite:///:memory:"}:
            common["poolclass"] = StaticPool
    else:
        common.update(
            pool_size=settings.db_pool_size,
            max_overflow=settings.db_max_overflow,
            pool_timeout=settings.db_pool_timeout,
            pool_recycle=settings.db_pool_recycle,
        )
    engine = create_engine(database_url, **common)
    if database_url.startswith("postgresql"):
        timeout_ms = settings.db_statement_timeout_ms

        def set_transaction_timeout(connection: Connection) -> None:
            apply_statement_timeout(connection, timeout_ms)

        event.listen(engine, "begin", set_transaction_timeout)
    return engine


def build_session_factory(engine: Engine) -> SessionFactory:
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_session(request: Request) -> Generator[Session, None, None]:
    """Yield one short-lived session and always roll back failed work."""

    factory: SessionFactory = request.app.state.session_factory
    session = factory()
    try:
        yield session
    except BaseException:
        session.rollback()
        raise
    finally:
        session.close()
