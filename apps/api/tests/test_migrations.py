"""Apply and reverse the complete Alembic history against a disposable database."""

from __future__ import annotations

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect


@pytest.mark.integration
def test_migrations_upgrade_and_downgrade(tmp_path: Path) -> None:
    api_root = Path(__file__).resolve().parents[1]
    database_path = tmp_path / "migration.db"
    url = f"sqlite+pysqlite:///{database_path.as_posix()}"
    config = Config(str(api_root / "alembic.ini"))
    config.set_main_option("script_location", str(api_root / "migrations"))
    config.set_main_option("sqlalchemy.url", url)

    command.upgrade(config, "head")

    engine = create_engine(url)
    inspector = inspect(engine)
    assert "items" in inspector.get_table_names()
    assert {column["name"] for column in inspector.get_columns("items")} == {
        "id",
        "name",
        "created_at",
    }
    assert {constraint["name"] for constraint in inspector.get_check_constraints("items")} == {
        "ck_items_name_length"
    }

    command.downgrade(config, "base")
    assert "items" not in inspect(engine).get_table_names()
    engine.dispose()
