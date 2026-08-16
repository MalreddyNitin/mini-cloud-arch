#!/usr/bin/env python3
"""Summarize Cloudflare R2 GraphQL analytics into free-tier meter classes.

The operation sets mirror Cloudflare's Standard storage pricing table. Unknown
action types are intentionally counted separately so a provider change cannot
silently under-report measured usage.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any


CLASS_A_OPERATIONS = frozenset(
    {
        "PutBucket",
        "PutObject",
        "CopyObject",
        "CompleteMultipartUpload",
        "CreateMultipartUpload",
        "LifecycleStorageTierTransition",
        "UploadPart",
        "UploadPartCopy",
        "ListBuckets",
        "ListObjects",
        "ListObjectsV2",
        "ListMultipartUploads",
        "ListParts",
        "PutBucketCors",
        "PutBucketLifecycleConfiguration",
        "PutBucketEncryption",
    }
)

CLASS_B_OPERATIONS = frozenset(
    {
        "HeadBucket",
        "HeadObject",
        "GetObject",
        "UsageSummary",
        "GetBucketLocation",
        "GetBucketCors",
        "GetBucketLifecycleConfiguration",
        "GetBucketEncryption",
    }
)

FREE_OPERATIONS = frozenset(
    {
        "DeleteObject",
        "DeleteBucket",
        "AbortMultipartUpload",
    }
)

if (CLASS_A_OPERATIONS & CLASS_B_OPERATIONS) or (
    (CLASS_A_OPERATIONS | CLASS_B_OPERATIONS) & FREE_OPERATIONS
):
    raise RuntimeError("R2 operation classes must be disjoint")


def _request_count(row: Mapping[str, Any]) -> int:
    return int((row.get("sum") or {}).get("requests") or 0)


def classify_operations(
    rows: Iterable[Mapping[str, Any]],
) -> tuple[int, int, int, int, dict[str, int]]:
    """Return Class A, Class B, free, unknown, and per-action request totals."""

    class_a = class_b = free = unknown = 0
    breakdown: dict[str, int] = {}
    for row in rows:
        name = str((row.get("dimensions") or {}).get("actionType") or "unknown")
        count = _request_count(row)
        breakdown[name] = breakdown.get(name, 0) + count
        if name in CLASS_A_OPERATIONS:
            class_a += count
        elif name in CLASS_B_OPERATIONS:
            class_b += count
        elif name in FREE_OPERATIONS:
            free += count
        else:
            unknown += count
    return class_a, class_b, free, unknown, breakdown


def summarize(payload: Mapping[str, Any]) -> dict[str, int | str]:
    """Parse the R2 analytics response and return shell-friendly totals."""

    if payload.get("errors"):
        raise ValueError("GraphQL errors: " + json.dumps(payload["errors"]))
    accounts = (
        (payload.get("data") or {}).get("viewer", {}).get("accounts", [])
    )
    if not accounts:
        raise ValueError("No R2 analytics account data returned")

    account = accounts[0]
    operation_rows = account.get("operations", [])
    class_a, class_b, free, unknown, breakdown = classify_operations(operation_rows)
    bucket_operations: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
    for row in operation_rows:
        dimensions = row.get("dimensions") or {}
        bucket_name = str(dimensions.get("bucketName") or "unknown-bucket")
        row_a, row_b, row_free, row_unknown, _ = classify_operations((row,))
        totals = bucket_operations[bucket_name]
        totals[0] += row_a
        totals[1] += row_b
        totals[2] += row_free
        totals[3] += row_unknown

    storage_rows = account.get("storage", [])
    storage_points: dict[tuple[str, str], int] = {}
    for row in storage_rows:
        dimensions = row.get("dimensions") or {}
        timestamp = str(dimensions.get("datetime") or "unknown-time")
        bucket_name = str(dimensions.get("bucketName") or "unknown-bucket")
        maximum = row.get("max") or {}
        row_bytes = int(maximum.get("payloadSize") or 0) + int(
            maximum.get("metadataSize") or 0
        )
        point = (timestamp, bucket_name)
        storage_points[point] = max(storage_points.get(point, 0), row_bytes)

    peak_storage_by_bucket: dict[str, int] = defaultdict(int)
    for (_, bucket_name), row_bytes in storage_points.items():
        peak_storage_by_bucket[bucket_name] = max(
            peak_storage_by_bucket[bucket_name], row_bytes
        )

    bucket_names = set(bucket_operations) | set(peak_storage_by_bucket)
    bucket_breakdown = []
    for bucket_name in sorted(bucket_names):
        bucket_a, bucket_b, bucket_free, bucket_unknown = bucket_operations[bucket_name]
        bucket_breakdown.append(
            f"{bucket_name}:storage_bytes={peak_storage_by_bucket[bucket_name]},"
            f"class_a={bucket_a},class_b={bucket_b},free_ops={bucket_free},"
            f"unknown_ops={bucket_unknown}"
        )

    return {
        # Sum each bucket's observed monthly peak. This can overstate concurrent
        # account usage when peaks occur at different times, but cannot
        # undercount merely because bucket timestamps are sparse/misaligned.
        "storage_bytes": sum(peak_storage_by_bucket.values()),
        "class_a": class_a,
        "class_b": class_b,
        "free_ops": free,
        "unknown_ops": unknown,
        "breakdown": ",".join(
            f"{name}:{count}" for name, count in sorted(breakdown.items())
        ),
        "bucket_breakdown": ";".join(bucket_breakdown),
        "analytics_rows_at_limit": int(
            len(operation_rows) >= 10_000 or len(storage_rows) >= 10_000
        ),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] in {"-h", "--help"}:
        print(f"Usage: {Path(argv[0]).name} RESPONSE_JSON", file=sys.stderr)
        return 0 if len(argv) == 2 else 2
    try:
        with Path(argv[1]).open(encoding="utf-8") as handle:
            summary = summarize(json.load(handle))
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    for name in (
        "storage_bytes",
        "class_a",
        "class_b",
        "free_ops",
        "unknown_ops",
        "breakdown",
        "bucket_breakdown",
        "analytics_rows_at_limit",
    ):
        print(f"{name}={summary[name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
