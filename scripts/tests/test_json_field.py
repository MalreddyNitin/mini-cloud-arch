from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import json_field  # noqa: E402


class JsonFieldTests(unittest.TestCase):
    def test_extracts_nested_field(self) -> None:
        self.assertEqual(json_field.extract({"result": {"id": "abc"}}, "result.id"), "abc")

    def test_missing_field_fails(self) -> None:
        with self.assertRaises(KeyError):
            json_field.extract({"status": "ok"}, "missing")


if __name__ == "__main__":
    unittest.main()
