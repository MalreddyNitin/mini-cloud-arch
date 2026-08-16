"""Small, bounded CRUD API for the vertical-slice relational model."""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_session
from app.models.item import Item
from app.schemas.item import ItemCreate, ItemList, ItemRead, ItemUpdate
from app.security import require_write_access

router = APIRouter(prefix="/api/items", tags=["items"])
SessionDependency = Annotated[Session, Depends(get_session)]
WriteAccess = Annotated[None, Depends(require_write_access)]


@router.get("", response_model=ItemList)
def list_items(
    request: Request,
    session: SessionDependency,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    offset: Annotated[int, Query(ge=0, le=10_000)] = 0,
) -> ItemList:
    if limit > request.app.state.settings.max_page_size:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"limit must not exceed {request.app.state.settings.max_page_size}",
        )

    rows = session.scalars(
        select(Item).order_by(Item.created_at.desc(), Item.id.desc()).limit(limit).offset(offset)
    ).all()
    total = session.scalar(select(func.count()).select_from(Item)) or 0
    return ItemList(
        items=[ItemRead.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post("", response_model=ItemRead, status_code=status.HTTP_201_CREATED)
def create_item(
    payload: ItemCreate,
    session: SessionDependency,
    _access: WriteAccess,
) -> Item:
    item = Item(name=payload.name)
    session.add(item)
    session.commit()
    session.refresh(item)
    return item


@router.patch("/{item_id}", response_model=ItemRead)
def update_item(
    item_id: UUID,
    payload: ItemUpdate,
    session: SessionDependency,
    _access: WriteAccess,
) -> Item:
    item = session.get(Item, item_id)
    if item is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="item not found")
    item.name = payload.name
    session.commit()
    session.refresh(item)
    return item


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_item(
    item_id: UUID,
    session: SessionDependency,
    _access: WriteAccess,
) -> Response:
    item = session.get(Item, item_id)
    if item is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="item not found")
    session.delete(item)
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
