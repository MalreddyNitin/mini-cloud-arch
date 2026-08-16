from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from verify_backup_metadata import BackupMetadataError, verify_backup_metadata  # noqa: E402


CHECKSUM = "ab" * 32


class BackupMetadataTests(unittest.TestCase):
    def test_exact_size_and_sha256_pass(self) -> None:
        verify_backup_metadata(
            {"ContentLength": 42, "Metadata": {"sha256": CHECKSUM.upper()}},
            expected_size=42,
            expected_sha256=CHECKSUM,
        )

    def test_size_mismatch_fails_closed(self) -> None:
        with self.assertRaisesRegex(BackupMetadataError, "ContentLength mismatch"):
            verify_backup_metadata(
                {"ContentLength": 41, "Metadata": {"sha256": CHECKSUM}},
                expected_size=42,
                expected_sha256=CHECKSUM,
            )

    def test_sha256_mismatch_fails_closed(self) -> None:
        with self.assertRaisesRegex(BackupMetadataError, "does not match"):
            verify_backup_metadata(
                {"ContentLength": 42, "Metadata": {"sha256": "cd" * 32}},
                expected_size=42,
                expected_sha256=CHECKSUM,
            )

    def test_missing_metadata_fails_closed(self) -> None:
        with self.assertRaisesRegex(BackupMetadataError, "metadata is missing"):
            verify_backup_metadata(
                {"ContentLength": 42},
                expected_size=42,
                expected_sha256=CHECKSUM,
            )


if __name__ == "__main__":
    unittest.main()
