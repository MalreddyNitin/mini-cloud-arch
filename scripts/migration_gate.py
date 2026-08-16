#!/usr/bin/env python3
"""Verify that an operator-set production migration marker matches Alembic head."""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path
from typing import Any


REVISION_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")


class MigrationGateError(ValueError):
    """Raised when the migration graph cannot be safely attested."""


def _module_value(tree: ast.Module, name: str) -> Any:
    for node in tree.body:
        value: ast.expr | None = None
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == name for target in node.targets
        ):
            value = node.value
        elif (
            isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == name
        ):
            value = node.value
        if value is not None:
            try:
                return ast.literal_eval(value)
            except (ValueError, TypeError) as exc:
                raise MigrationGateError(
                    f"{name} must be a literal in an Alembic revision"
                ) from exc
    raise MigrationGateError(f"missing {name} declaration")


def repository_heads(versions_dir: Path) -> set[str]:
    """Read an Alembic versions directory without importing application code."""

    if not versions_dir.is_dir():
        raise MigrationGateError(f"versions directory not found: {versions_dir}")
    revisions: set[str] = set()
    parents: set[str] = set()
    files = sorted(path for path in versions_dir.glob("*.py") if path.name != "__init__.py")
    if not files:
        raise MigrationGateError(f"no Alembic revisions found in {versions_dir}")

    for path in files:
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except (OSError, SyntaxError) as exc:
            raise MigrationGateError(f"cannot parse {path}: {exc}") from exc
        revision = _module_value(tree, "revision")
        down_revision = _module_value(tree, "down_revision")
        if not isinstance(revision, str) or not REVISION_PATTERN.fullmatch(revision):
            raise MigrationGateError(f"invalid revision identifier in {path}")
        if revision in revisions:
            raise MigrationGateError(f"duplicate Alembic revision: {revision}")
        revisions.add(revision)

        if down_revision is None:
            continue
        parent_values = (
            down_revision if isinstance(down_revision, (tuple, list)) else (down_revision,)
        )
        if not parent_values or not all(
            isinstance(parent, str) and REVISION_PATTERN.fullmatch(parent)
            for parent in parent_values
        ):
            raise MigrationGateError(f"invalid down_revision in {path}")
        parents.update(parent_values)

    missing_parents = parents - revisions
    if missing_parents:
        raise MigrationGateError(
            "migration graph references missing revisions: "
            + ", ".join(sorted(missing_parents))
        )
    return revisions - parents


def verify(expected: str, versions_dir: Path) -> str:
    if not REVISION_PATTERN.fullmatch(expected):
        raise MigrationGateError("expected revision has an invalid format")
    heads = repository_heads(versions_dir)
    if len(heads) != 1:
        raise MigrationGateError(
            "deployment requires exactly one Alembic head; found: "
            + ", ".join(sorted(heads))
        )
    head = next(iter(heads))
    if expected != head:
        raise MigrationGateError(
            f"production migration marker {expected!r} does not match repository head {head!r}"
        )
    return head


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail unless an operator-attested production revision matches the "
            "single Alembic head in the repository."
        )
    )
    parser.add_argument("--expected", required=True, help="operator-attested revision")
    parser.add_argument(
        "--versions-dir",
        type=Path,
        default=Path("apps/api/migrations/versions"),
        help="Alembic versions directory",
    )
    args = parser.parse_args(argv)
    try:
        head = verify(args.expected, args.versions_dir)
    except MigrationGateError as exc:
        print(f"Migration gate failed: {exc}", file=sys.stderr)
        return 1
    print(f"Migration gate passed: production is attested at {head}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
