"""Check Portico declarations against the SDK's version-specific wire model."""

import json
import os
from pathlib import Path
import subprocess
import unittest

from mcp_types._v2026_07_28 import ListToolsResult
from pydantic import ValidationError


class ToolSchemaContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        process = subprocess.run(
            ["mix", "run", "e2e/schema_probe.exs"],
            cwd=Path(__file__).resolve().parents[1],
            env=dict(os.environ, MIX_ENV="test"),
            capture_output=True, text=True, timeout=45,
        )
        if process.returncode:
            raise RuntimeError(process.stdout + process.stderr)
        marker = "PORTICO_SCHEMA_PROBE="
        cls.cases = {
            item["name"]: item
            for line in process.stdout.splitlines() if line.startswith(marker)
            for item in json.loads(line[len(marker):])
        }
        if len(cls.cases) != 6:
            raise RuntimeError("Missing schema probe results: " + process.stdout)

    def test_invalid_roots_are_rejected_before_listing(self):
        for name in ("missing", "array", "union", "reference_only"):
            with self.subTest(schema=name):
                case = self.cases[name]
                if case["compiled"]:
                    # Before the fix, Portico publishes a definition that the
                    # official SDK's 2026-07-28 wire model rejects.
                    with self.assertRaises(ValidationError):
                        ListToolsResult.model_validate(case["result"])
                    self.fail(f"Portico compiled {name!r}; Python MCP wire validation rejects its tools/list result")
                self.assertIn('input_schema must declare type: "object" at the root', case["error"])

    def test_object_roots_and_composition_are_valid_on_the_wire(self):
        for name in ("object", "composition"):
            with self.subTest(schema=name):
                case = self.cases[name]
                self.assertTrue(case["compiled"], case.get("error"))
                result = ListToolsResult.model_validate(case["result"])
                self.assertEqual(result.tools[0].input_schema.type, "object")
                if name == "composition":
                    self.assertIn("allOf", case["result"]["tools"][0]["inputSchema"])
                    self.assertIn("$defs", case["result"]["tools"][0]["inputSchema"])
