from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import r2_usage  # noqa: E402


class R2UsageTests(unittest.TestCase):
    def test_list_operations_are_class_a(self) -> None:
        names = (
            "ListObjects",
            "ListObjectsV2",
            "ListMultipartUploads",
            "ListParts",
        )
        rows = [
            {"dimensions": {"actionType": name}, "sum": {"requests": index}}
            for index, name in enumerate(names, start=1)
        ]

        class_a, class_b, free, unknown, _ = r2_usage.classify_operations(rows)

        self.assertEqual(class_a, 10)
        self.assertEqual(class_b, 0)
        self.assertEqual(free, 0)
        self.assertEqual(unknown, 0)

    def test_known_and_unknown_operations_are_not_dropped(self) -> None:
        rows = [
            {"dimensions": {"actionType": "PutObject"}, "sum": {"requests": 2}},
            {"dimensions": {"actionType": "GetObject"}, "sum": {"requests": 3}},
            {"dimensions": {"actionType": "DeleteObject"}, "sum": {"requests": 4}},
            {"dimensions": {"actionType": "FutureOperation"}, "sum": {"requests": 5}},
            {"dimensions": {"actionType": "DeleteObjects"}, "sum": {"requests": 6}},
        ]

        class_a, class_b, free, unknown, breakdown = r2_usage.classify_operations(rows)

        self.assertEqual((class_a, class_b, free, unknown), (2, 3, 4, 11))
        self.assertEqual(sum(breakdown.values()), 20)

    def test_storage_sums_each_bucket_peak_even_at_disjoint_times(self) -> None:
        payload = {
            "data": {
                "viewer": {
                    "accounts": [
                        {
                            "operations": [
                                {
                                    "dimensions": {
                                        "actionType": "ListObjects",
                                        "bucketName": "one",
                                    },
                                    "sum": {"requests": 7},
                                },
                                {
                                    "dimensions": {
                                        "actionType": "GetObject",
                                        "bucketName": "two",
                                    },
                                    "sum": {"requests": 9},
                                },
                            ],
                            "storage": [
                                {
                                    "dimensions": {"datetime": "t1", "bucketName": "one"},
                                    "max": {"payloadSize": 90, "metadataSize": 5},
                                },
                                {
                                    "dimensions": {"datetime": "t1", "bucketName": "two"},
                                    "max": {"payloadSize": 100, "metadataSize": 3},
                                },
                                {
                                    "dimensions": {"datetime": "t2", "bucketName": "one"},
                                    "max": {"payloadSize": 150, "metadataSize": 0},
                                },
                            ],
                        }
                    ]
                }
            }
        }

        summary = r2_usage.summarize(payload)
        self.assertEqual(summary["storage_bytes"], 253)
        self.assertEqual(summary["class_a"], 7)
        self.assertEqual(summary["class_b"], 9)
        self.assertIn("one:storage_bytes=150", summary["bucket_breakdown"])
        self.assertIn("two:storage_bytes=103", summary["bucket_breakdown"])


if __name__ == "__main__":
    unittest.main()
