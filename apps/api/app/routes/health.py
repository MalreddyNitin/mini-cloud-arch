"""Liveness and dependency-readiness endpoints."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.db import get_session

router = APIRouter(tags=["health"])
SessionDependency = Annotated[Session, Depends(get_session)]


@router.get("/health", summary="Process liveness")
def health() -> dict[str, str]:
    """Report process health without touching external services."""

    return {"status": "ok"}


@router.get("/ready", summary="Database readiness")
def ready(session: SessionDependency) -> dict[str, str]:
    try:
        session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="database unavailable",
        ) from exc
    return {"status": "ready"}
