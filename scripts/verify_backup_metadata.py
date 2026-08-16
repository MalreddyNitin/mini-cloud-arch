#!/usr/bin/env python3
"""Fail-closed verification for an R2/S3 ``head-object`` backup response."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SHA256_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")


class BackupMetadataError(ValueError):
    """Raised when remote backup evidence is missing, malformed, or mismatched."""


def verify_backup_metadata(
    payload: Any,
    *,
    expected_size: int,
    expected_sha256: str,
) -> None:
    """Verify exact content length and operator-recorded SHA-256 metadata."""

    expected_sha256 = expected_sha256.lower()
    if expected_size < 0:
        raise BackupMetadataError("expected size must not be negative")
    if not SHA256_PATTERN.fullmatch(expected_sha256):
        raise BackupMetadataError("expected SHA-256 must be 64 hexadecimal characters")
    if not isinstance(payload, dict):
        raise BackupMetadataError("head-object response must be a JSON object")

    remote_size = payload.get("ContentLength")
    if isinstance(remote_size, bool) or not isinstance(remote_size, int):
        raise BackupMetadataError("remote ContentLength is missing or invalid")
    if remote_size != expected_size:
        raise BackupMetadataError(
            f"remote ContentLength mismatch: expected {expected_size}, observed {remote_size}"
        )

    metadata = payload.get("Metadata")
    if not isinstance(metadata, dict):
        raise BackupMetadataError("remote SHA-256 metadata is missing")
    normalized_metadata = {
        str(key).lower(): str(value).lower() for key, value in metadata.items()
    }
    remote_sha256 = normalized_metadata.get("sha256", "")
    if not SHA256_PATTERN.fullmatch(remote_sha256):
        raise BackupMetadataError("remote SHA-256 metadata is missing or invalid")
    if remote_sha256 != expected_sha256:
        raise BackupMetadataError(
            "remote SHA-256 metadata does not match the local dump"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("head_object_json", type=Path)
    parser.add_argument("--expected-size", type=int, required=True)
    parser.add_argument("--expected-sha256", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with args.head_object_json.open(encoding="utf-8") as handle:
            payload = json.load(handle)
        verify_backup_metadata(
            payload,
            expected_size=args.expected_size,
            expected_sha256=args.expected_sha256,
        )
    except (OSError, json.JSONDecodeError, BackupMetadataError) as exc:
        print(f"Backup metadata verification failed: {exc}", file=sys.stderr)
        return 1
    print(
        f"Verified remote backup metadata: size_bytes={args.expected_size} "
        f"sha256={args.expected_sha256.lower()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
