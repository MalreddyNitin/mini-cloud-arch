"""FastAPI application factory."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import Engine
from sqlalchemy.exc import SQLAlchemyError

from app import __version__
from app.config import Settings, get_settings
from app.db import build_engine, build_session_factory
from app.logging import configure_logging
from app.middleware import RequestObservabilityMiddleware
from app.routes import files_router, health_router, items_router
from app.services.storage import R2Storage

logger = logging.getLogger("zero_cloud")


def create_app(
    settings: Settings | None = None,
    *,
    engine: Engine | None = None,
    storage: R2Storage | None = None,
) -> FastAPI:
    runtime_settings = settings or get_settings()
    configure_logging(runtime_settings.log_level)
    runtime_engine = engine or build_engine(runtime_settings)

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        logger.info("application_started", extra={"app_env": runtime_settings.app_env})
        try:
            yield
        finally:
            runtime_engine.dispose()
            logger.info("application_stopped")

    expose_docs = runtime_settings.app_env != "production"
    application = FastAPI(
        title="Zero Cloud Stack API",
        version=__version__,
        docs_url="/docs" if expose_docs else None,
        redoc_url=None,
        openapi_url="/openapi.json" if expose_docs else None,
        lifespan=lifespan,
    )
    application.state.settings = runtime_settings
    application.state.engine = runtime_engine
    application.state.session_factory = build_session_factory(runtime_engine)
    application.state.storage = storage or R2Storage(runtime_settings)

    application.add_middleware(RequestObservabilityMiddleware)
    application.add_middleware(GZipMiddleware, minimum_size=1024)
    application.add_middleware(
        CORSMiddleware,
        allow_origins=list(runtime_settings.cors_origin_list),
        allow_credentials=False,
        allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
        expose_headers=["X-Request-ID"],
        max_age=600,
    )

    application.include_router(health_router)
    application.include_router(items_router)
    application.include_router(files_router)

    @application.exception_handler(SQLAlchemyError)
    async def database_error_handler(_request: Request, exc: SQLAlchemyError) -> JSONResponse:
        # Never stringify SQL errors: driver messages can include infrastructure details.
        logger.warning("database_operation_failed", extra={"error_type": type(exc).__name__})
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"detail": "database unavailable"},
        )

    return application


# Uvicorn and ASGI platforms import this symbol. Settings are validated at startup/import.
app = create_app()
