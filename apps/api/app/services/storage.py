"""Private R2/S3 presigning with server-owned object names and strict bounds."""

from __future__ import annotations

import re
import unicodedata
from datetime import UTC, datetime
from typing import Any, Protocol
from uuid import uuid4

from app.config import Settings


class PresignClient(Protocol):
    def generate_presigned_url(
        self,
        client_method: str,
        Params: dict[str, Any],
        ExpiresIn: int,
        HttpMethod: str,
    ) -> str: ...


SAFE_NAME_PATTERN = re.compile(r"[^A-Za-z0-9._-]+")
GENERATED_KEY_PATTERN = re.compile(
    r"\Auploads/public/\d{4}/(?:0[1-9]|1[0-2])/[0-9a-f]{32}-[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z"
)


class StorageError(RuntimeError):
    """An object-storage operation could not be completed."""


class StorageConfigurationError(StorageError):
    """Object storage is disabled or incompletely configured."""


def sanitize_filename(filename: str) -> str:
    """Reduce a user label to a short basename; it never becomes the complete key."""

    basename = filename.replace("\\", "/").rsplit("/", maxsplit=1)[-1]
    ascii_name = unicodedata.normalize("NFKD", basename).encode("ascii", "ignore").decode("ascii")
    safe = SAFE_NAME_PATTERN.sub("-", ascii_name).strip("._-")
    if not safe:
        safe = "file"
    return safe[:80]


def make_upload_key(filename: str, *, now: datetime | None = None) -> str:
    timestamp = now or datetime.now(UTC)
    safe_name = sanitize_filename(filename)
    return f"uploads/public/{timestamp:%Y}/{timestamp:%m}/{uuid4().hex}-{safe_name}"


def validate_download_key(key: str) -> str:
    """Only permit keys created by ``make_upload_key`` in the public upload namespace."""

    if not GENERATED_KEY_PATTERN.fullmatch(key):
        raise ValueError("invalid object key")
    return key


class R2Storage:
    """Generate short-lived signed URLs without moving object bytes through the API."""

    def __init__(self, settings: Settings, client: PresignClient | Any | None = None) -> None:
        self._settings = settings
        self._client_override = client

    @property
    def expires_in(self) -> int:
        return self._settings.presign_expires_seconds

    def _client(self) -> PresignClient | Any:
        if self._client_override is not None:
            return self._client_override
        if not self._settings.r2_is_configured:
            raise StorageConfigurationError("object storage is not configured")

        # Import lazily so ordinary unit tests and health endpoints need no cloud SDK setup.
        import boto3
        from botocore.config import Config

        access_key = self._settings.r2_access_key_id
        secret_key = self._settings.r2_secret_access_key
        assert access_key is not None and secret_key is not None
        try:
            return boto3.client(
                "s3",
                endpoint_url=self._settings.r2_endpoint_url,
                aws_access_key_id=access_key.get_secret_value(),
                aws_secret_access_key=secret_key.get_secret_value(),
                region_name="auto",
                config=Config(
                    signature_version="s3v4",
                    retries={"max_attempts": 2, "mode": "standard"},
                    connect_timeout=3,
                    read_timeout=5,
                    s3={"addressing_style": "path"},
                ),
            )
        except Exception as exc:  # boto3 may raise several configuration-specific types
            raise StorageConfigurationError("object storage client could not be created") from exc

    def presign_upload(
        self,
        *,
        filename: str,
        content_type: str,
        size_bytes: int,
    ) -> tuple[str, str, dict[str, str]]:
        if content_type not in self._settings.allowed_content_type_set:
            raise ValueError("content type is not allowed")
        if size_bytes < 1 or size_bytes > self._settings.max_upload_bytes:
            raise ValueError(
                f"file size must be between 1 and {self._settings.max_upload_bytes} bytes"
            )
        if not self._settings.r2_is_configured and self._client_override is None:
            raise StorageConfigurationError("object storage is not configured")

        key = make_upload_key(filename)
        params = {
            "Bucket": self._settings.r2_bucket,
            "Key": key,
            "ContentType": content_type,
            # SigV4 includes this in X-Amz-SignedHeaders. R2 therefore rejects a body whose
            # actual Content-Length differs from the server-authorized size.
            "ContentLength": size_bytes,
        }
        try:
            url = self._client().generate_presigned_url(
                "put_object",
                Params=params,
                ExpiresIn=self._settings.presign_expires_seconds,
                HttpMethod="PUT",
            )
        except StorageError:
            raise
        except Exception as exc:
            raise StorageError("upload URL could not be generated") from exc
        return url, key, {"Content-Type": content_type}

    def presign_download(self, key: str) -> str:
        safe_key = validate_download_key(key)
        if not self._settings.r2_is_configured and self._client_override is None:
            raise StorageConfigurationError("object storage is not configured")
        try:
            return self._client().generate_presigned_url(
                "get_object",
                Params={"Bucket": self._settings.r2_bucket, "Key": safe_key},
                ExpiresIn=self._settings.presign_expires_seconds,
                HttpMethod="GET",
            )
        except StorageError:
            raise
        except Exception as exc:
            raise StorageError("download URL could not be generated") from exc
