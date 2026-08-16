#!/usr/bin/env python3
"""Read one dotted field from a JSON object without shell evaluation."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def extract(value: Any, dotted_field: str) -> Any:
    current = value
    for part in dotted_field.split("."):
        if not part or not isinstance(current, dict) or part not in current:
            raise KeyError(dotted_field)
        current = current[part]
    return current


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"Usage: {Path(argv[0]).name} JSON_FILE DOTTED_FIELD", file=sys.stderr)
        return 2
    try:
        with Path(argv[1]).open(encoding="utf-8") as handle:
            value = extract(json.load(handle), argv[2])
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"Unable to read JSON field {argv[2]!r}: {exc}", file=sys.stderr)
        return 1
    if isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(",", ":")))
    elif value is None:
        print("null")
    elif isinstance(value, bool):
        print(str(value).lower())
    else:
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
