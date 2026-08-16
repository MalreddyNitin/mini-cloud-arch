from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = "scripts/smoke-test.sh"
TEN_MIB = 10 * 1024 * 1024


def find_working_bash() -> str | None:
    candidates: list[str | None] = []
    if os.name == "nt":
        candidates.extend(
            [
                r"C:\Program Files\Git\bin\bash.exe",
                r"C:\Program Files\Git\usr\bin\bash.exe",
            ]
        )
    candidates.append(shutil.which("bash"))
    for candidate in candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        try:
            result = subprocess.run(
                [candidate, "--version"], capture_output=True, timeout=5, check=False
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0:
            return candidate
    return None


BASH = find_working_bash()


@unittest.skipUnless(BASH, "a working Bash is required")
class SmokeContractTests(unittest.TestCase):
    def run_smoke_validation(
        self, *args: str, max_upload_bytes: int = TEN_MIB
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["MAX_UPLOAD_BYTES"] = str(max_upload_bytes)
        return subprocess.run(
            [
                str(BASH),
                str(SCRIPT),
                "--api-url",
                "http://127.0.0.1:1",
                "--r2",
                *args,
            ],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_r2_payload_cannot_be_smaller_than_acceptance_minimum(self) -> None:
        result = self.run_smoke_validation("--r2-size-bytes", str(TEN_MIB - 1))

        self.assertEqual(result.returncode, 2)
        self.assertIn("between 10 MiB and 100 MiB", result.stderr)

    def test_r2_payload_cannot_exceed_application_cap(self) -> None:
        result = self.run_smoke_validation(
            "--r2-size-bytes", str(TEN_MIB + 1), max_upload_bytes=TEN_MIB
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("exceeds MAX_UPLOAD_BYTES", result.stderr)

    def test_r2_payload_cannot_exceed_hard_api_limit(self) -> None:
        result = self.run_smoke_validation(
            "--r2-size-bytes",
            str(100 * 1024 * 1024 + 1),
            max_upload_bytes=200 * 1024 * 1024,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("between 10 MiB and 100 MiB", result.stderr)


if __name__ == "__main__":
    unittest.main()
