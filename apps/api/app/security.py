"""Small authorization dependency for the deliberately bounded write surface."""

from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import Header, HTTPException, Request, status

from app.config import Settings


def get_request_settings(request: Request) -> Settings:
    settings: Settings = request.app.state.settings
    return settings


def require_write_access(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    """Disable writes by default and protect configured write surfaces with Bearer auth."""

    settings = get_request_settings(request)
    if not settings.enable_writes:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="write operations are disabled",
        )

    configured = settings.write_api_key
    if configured is None:
        # Only development/test settings may reach this state; production validation rejects it.
        return

    prefix = "Bearer "
    supplied = (
        authorization[len(prefix) :] if authorization and authorization.startswith(prefix) else ""
    )
    if not supplied or not secrets.compare_digest(supplied, configured.get_secret_value()):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing write credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
