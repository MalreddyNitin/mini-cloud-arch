"""Cloud Run/Uvicorn entrypoint behavior."""

from __future__ import annotations

import logging
from typing import Any

from app.__main__ import main
from app.config import Settings
from app.logging import configure_logging


def test_entrypoint_disables_raw_access_logs(monkeypatch) -> None:
    settings = Settings(_env_file=None, app_env="test", port=9123)
    call: dict[str, Any] = {}

    def fake_run(application: str, **kwargs: Any) -> None:
        call["application"] = application
        call.update(kwargs)

    monkeypatch.setattr("app.__main__.get_settings", lambda: settings)
    monkeypatch.setattr("app.__main__.uvicorn.run", fake_run)

    main()

    assert call["application"] == "app.main:app"
    assert call["port"] == 9123
    assert call["timeout_graceful_shutdown"] == 10
    assert call["access_log"] is False


def test_logging_configuration_disables_uvicorn_access_logger() -> None:
    access_logger = logging.getLogger("uvicorn.access")
    access_logger.disabled = False
    access_logger.addHandler(logging.NullHandler())

    configure_logging("INFO")

    assert access_logger.disabled is True
    assert access_logger.handlers == []
    assert access_logger.propagate is False
