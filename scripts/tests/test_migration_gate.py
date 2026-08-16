from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import migration_gate  # noqa: E402


class MigrationGateTests(unittest.TestCase):
    def test_matching_single_head_passes(self) -> None:
        versions = Path("apps/api/migrations/versions")
        heads = migration_gate.repository_heads(versions)
        self.assertEqual(len(heads), 1)
        head = next(iter(heads))

        self.assertEqual(migration_gate.verify(head, versions), head)

    def test_stale_marker_fails(self) -> None:
        with mock.patch.object(migration_gate, "repository_heads", return_value={"0002"}):
            with self.assertRaisesRegex(
                migration_gate.MigrationGateError, "does not match repository head"
            ):
                migration_gate.verify("0001", Path("unused"))

    def test_multiple_heads_fail_closed(self) -> None:
        with mock.patch.object(
            migration_gate, "repository_heads", return_value={"0002", "0003"}
        ):
            with self.assertRaisesRegex(
                migration_gate.MigrationGateError, "exactly one Alembic head"
            ):
                migration_gate.verify("0002", Path("unused"))


if __name__ == "__main__":
    unittest.main()
