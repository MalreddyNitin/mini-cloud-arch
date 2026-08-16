"""ASGI middleware for request correlation, safe structured logs, and headers."""

from __future__ import annotations

import logging
import re
from time import perf_counter
from typing import Any
from uuid import uuid4

from starlette.types import ASGIApp, Message, Receive, Scope, Send

REQUEST_ID_PATTERN = re.compile(r"\A[A-Za-z0-9._-]{1,64}\Z")
logger = logging.getLogger("zero_cloud.request")

SECURITY_HEADERS: tuple[tuple[bytes, bytes], ...] = (
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"permissions-policy", b"camera=(), microphone=(), geolocation=()"),
    (b"content-security-policy", b"default-src 'none'; frame-ancestors 'none'"),
    (b"strict-transport-security", b"max-age=31536000; includeSubDomains"),
    (b"cache-control", b"no-store"),
)


def _header_value(scope: Scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key.lower() == name:
            return bytes(value).decode("latin-1")
    return None


class RequestObservabilityMiddleware:
    """Log request metadata only—never headers, query strings, bodies, or signed URLs."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming_id = _header_value(scope, b"x-request-id")
        request_id = (
            incoming_id
            if incoming_id and REQUEST_ID_PATTERN.fullmatch(incoming_id)
            else uuid4().hex
        )
        scope.setdefault("state", {})["request_id"] = request_id
        method = str(scope.get("method", ""))
        started = perf_counter()
        status_code = 500

        async def send_with_headers(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message["status"])
                headers = list(message.get("headers", []))
                existing = {key.lower() for key, _ in headers}
                if b"x-request-id" not in existing:
                    headers.append((b"x-request-id", request_id.encode("ascii")))
                headers.extend(
                    (key, value) for key, value in SECURITY_HEADERS if key not in existing
                )
                message["headers"] = headers
            await send(message)

        error_type: str | None = None
        try:
            await self.app(scope, receive, send_with_headers)
        except BaseException as exc:
            error_type = type(exc).__name__
            raise
        finally:
            duration_ms = round((perf_counter() - started) * 1000, 2)
            route_path = getattr(scope.get("route"), "path", None)
            safe_path = route_path if isinstance(route_path, str) else "<unmatched>"
            extra: dict[str, Any] = {
                "request_id": request_id,
                "method": method,
                "path": safe_path,
                "status": status_code,
                "duration_ms": duration_ms,
            }
            if error_type:
                # Only the class name is logged to avoid leaking DSNs, tokens, or signed URLs.
                extra["error_type"] = error_type
            logger.info("request_complete", extra=extra)
