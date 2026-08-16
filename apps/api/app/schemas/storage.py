"""Validation models for direct-to-R2 transfers."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class PresignUploadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    filename: Annotated[str, Field(min_length=1, max_length=255)]
    content_type: Annotated[str, Field(min_length=1, max_length=100)]
    size_bytes: Annotated[int, Field(ge=1)]

    @field_validator("filename")
    @classmethod
    def reject_control_characters(cls, value: str) -> str:
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("filename contains control characters")
        return value

    @field_validator("content_type")
    @classmethod
    def normalize_content_type(cls, value: str) -> str:
        # Content-Type parameters are not signed: clients must upload the normalized media type.
        return value.split(";", maxsplit=1)[0].strip().lower()


class PresignedUpload(BaseModel):
    upload_url: str
    key: str
    method: Literal["PUT"] = "PUT"
    headers: dict[str, str]
    expires_in: int


class PresignedDownload(BaseModel):
    download_url: str
    key: str
    expires_in: int
