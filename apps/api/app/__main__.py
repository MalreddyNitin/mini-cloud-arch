"""Container entrypoint that honors Cloud Run's PORT environment contract."""

from __future__ import annotations

import uvicorn

from app.config import get_settings


def main() -> None:
    settings = get_settings()
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=settings.port,
        log_level=settings.log_level.lower(),
        proxy_headers=True,
        forwarded_allow_ips="*",
        timeout_graceful_shutdown=10,
        access_log=False,
    )


if __name__ == "__main__":
    main()
