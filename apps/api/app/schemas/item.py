"""Validation models for the item API."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, StringConstraints

ItemName = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=120),
]


class ItemCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: ItemName


class ItemUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: ItemName


class ItemRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    created_at: datetime


class ItemList(BaseModel):
    items: list[ItemRead]
    total: int
    limit: int
    offset: int
