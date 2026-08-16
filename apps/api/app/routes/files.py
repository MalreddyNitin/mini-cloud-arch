"""Endpoints that authorize direct browser-to-R2 transfers."""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.schemas.storage import PresignedDownload, PresignedUpload, PresignUploadRequest
from app.security import require_write_access
from app.services.storage import R2Storage, StorageConfigurationError, StorageError

router = APIRouter(prefix="/api/files", tags=["files"])
logger = logging.getLogger("zero_cloud")
WriteAccess = Annotated[None, Depends(require_write_access)]


def get_storage(request: Request) -> R2Storage:
    storage: R2Storage = request.app.state.storage
    return storage


StorageDependency = Annotated[R2Storage, Depends(get_storage)]


def _storage_http_error(exc: StorageError) -> HTTPException:
    if isinstance(exc, StorageConfigurationError):
        detail = "object storage is unavailable"
    else:
        detail = "object storage request failed"
    logger.warning("storage_presign_failed", extra={"error_type": type(exc).__name__})
    return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=detail)


@router.post("/presign-upload", response_model=PresignedUpload)
def presign_upload(
    payload: PresignUploadRequest,
    storage: StorageDependency,
    _access: WriteAccess,
) -> PresignedUpload:
    try:
        url, key, headers = storage.presign_upload(
            filename=payload.filename,
            content_type=payload.content_type,
            size_bytes=payload.size_bytes,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc
    except StorageError as exc:
        raise _storage_http_error(exc) from exc

    return PresignedUpload(
        upload_url=url,
        key=key,
        headers=headers,
        expires_in=storage.expires_in,
    )


@router.get("/{key:path}/presign-download", response_model=PresignedDownload)
def presign_download(
    key: str,
    storage: StorageDependency,
    _access: WriteAccess,
) -> PresignedDownload:
    try:
        url = storage.presign_download(key)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="invalid object key",
        ) from exc
    except StorageError as exc:
        raise _storage_http_error(exc) from exc
    return PresignedDownload(
        download_url=url,
        key=key,
        expires_in=storage.expires_in,
    )
