#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY_ROOT / "Scripts" / "check-package-resolution.py"


def pin(identity, version="1.2.3", revision="a" * 40, **state_overrides):
    state = {"version": version, "revision": revision}
    state.update(state_overrides)
    return {
        "identity": identity,
        "kind": "remoteSourceControl",
        "location": f"https://example.invalid/{identity}.git",
        "state": state,
    }


def lock(*pins):
    return {"pins": list(pins), "version": 2}


class PackageResolutionCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        root = Path(self.temporary_directory.name)
        self.authoritative = root / "authoritative" / "Package.resolved"
        self.workspace = root / "workspace" / "Package.resolved"

    @staticmethod
    def write_json(path, payload):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def run_checker(self):
        return subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                "--authoritative",
                str(self.authoritative),
                "--workspace",
                str(self.workspace),
            ],
            cwd=REPOSITORY_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_matching_graph_accepts_case_and_pin_order_differences(self):
        self.write_json(
            self.authoritative,
            lock(pin("Alpha"), pin("beta", version="4.5.6", revision="b" * 40)),
        )
        self.write_json(
            self.workspace,
            lock(pin("BETA", version="4.5.6", revision="b" * 40), pin("alpha")),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatching_graph_is_rejected(self):
        self.write_json(self.authoritative, lock(pin("alpha")))
        self.write_json(self.workspace, lock(pin("alpha", revision="b" * 40)))

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("graph mismatch", result.stderr)

    def test_missing_authoritative_lock_is_rejected(self):
        self.write_json(self.workspace, lock(pin("alpha")))

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authoritative lock does not exist", result.stderr)

    def test_missing_optional_workspace_lock_is_permitted(self):
        self.write_json(self.authoritative, lock(pin("alpha")))

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_normalized_identity_is_rejected(self):
        self.write_json(self.authoritative, lock(pin("Alpha"), pin("alpha")))

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate package identity", result.stderr)

    def test_mutable_branch_state_is_rejected(self):
        self.write_json(
            self.authoritative,
            lock(pin("alpha", branch="main")),
        )

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mutable branch", result.stderr)

    def test_malformed_authoritative_json_is_rejected(self):
        self.authoritative.parent.mkdir(parents=True, exist_ok=True)
        self.authoritative.write_text("{not-json", encoding="utf-8")

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid JSON", result.stderr)

    def test_missing_pins_array_is_rejected(self):
        self.write_json(self.authoritative, {"version": 2})

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pins array", result.stderr)

    def test_missing_lock_schema_version_is_rejected(self):
        self.write_json(self.authoritative, {"pins": [pin("alpha")]})

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("supported version", result.stderr)

    def test_unsupported_lock_schema_version_is_rejected(self):
        self.write_json(self.authoritative, {"pins": [pin("alpha")], "version": 99})

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported version", result.stderr)

    def test_malformed_pin_state_is_rejected(self):
        malformed_pin = pin("alpha")
        malformed_pin["state"] = []
        self.write_json(self.authoritative, lock(malformed_pin))

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("state must be an object", result.stderr)

    def test_missing_immutable_state_value_is_rejected(self):
        malformed_pin = pin("alpha")
        del malformed_pin["state"]["version"]
        self.write_json(self.authoritative, lock(malformed_pin))

        result = self.run_checker()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-empty version and revision", result.stderr)


if __name__ == "__main__":
    unittest.main()
