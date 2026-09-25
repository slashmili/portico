"""Real HTTP checks with an owned Elixir server, or an explicit MCP_URL."""

import asyncio
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

from jsonschema import Draft202012Validator
from mcp import Client
from mcp.types import TextContent

URL = os.environ.get("MCP_URL")
PROTOCOL_VERSION = "2026-07-28"


def setUpModule():
    global URL
    if URL:
        print(f"Testing external server: {URL}", flush=True)
        return

    temporary = tempfile.TemporaryDirectory(prefix="portico-e2e-")
    unittest.addModuleCleanup(temporary.cleanup)
    ready = Path(temporary.name) / "port"
    log_path = Path(temporary.name) / "server.log"
    output = log_path.open("w")
    unittest.addModuleCleanup(output.close)
    environment = dict(os.environ, MIX_ENV="test", PORTICO_E2E_READY_FILE=str(ready))
    process = subprocess.Popen(
        ["mix", "run", "e2e/server.exs"],
        cwd=Path(__file__).resolve().parents[1],
        env=environment,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    def stop_server():
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

    unittest.addModuleCleanup(stop_server)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        if ready.exists() and (port := ready.read_text().strip()):
            URL = f"http://127.0.0.1:{int(port)}/mcp"
            print(f"Testing fresh example server: {URL}", flush=True)
            return
        time.sleep(0.05)

    raise RuntimeError(
        "Example server did not start. Run `mix deps.get` in example/.\n"
        + log_path.read_text()[-8000:]
    )


class PorticoHTTPTest(unittest.IsolatedAsyncioTestCase):
    async def test_discovery(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                self.assertEqual(client.protocol_version, PROTOCOL_VERSION)
                self.assertEqual(client.server_info.name, "portico-example")
                self.assertEqual(client.server_info.version, "0.1.0")
                self.assertIsNotNone(client.server_capabilities.tools)
                discovery = await client.session.discover()
                self.assertEqual(discovery.supported_versions, [PROTOCOL_VERSION])
                self.assertEqual(discovery.cache_scope, "private")
                self.assertEqual(discovery.ttl_ms, 0)

    async def test_tool_listing(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                self.assertEqual(client.protocol_version, PROTOCOL_VERSION)
                listing = await client.list_tools()
                self.assertEqual([tool.name for tool in listing.tools], ["add", "count"])
                self.assertIsNone(listing.next_cursor)
                self.assertEqual(listing.cache_scope, "private")
                self.assertEqual(listing.ttl_ms, 0)
                for listed_tool in listing.tools:
                    Draft202012Validator.check_schema(listed_tool.input_schema)
                tool = listing.tools[0]
                Draft202012Validator.check_schema(tool.input_schema)
                self.assertEqual(tool.description, "Add two integers.")
                self.assertEqual(tool.input_schema, {
                    "type": "object",
                    "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                    "required": ["a", "b"],
                    "additionalProperties": False,
                })

    async def test_add(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                self.assertEqual(client.protocol_version, PROTOCOL_VERSION)
                for a, b, expected in [(2, 3, "5"), (-4, 2, "-2"), (0, 0, "0"), (2.0, 3.0, "5")]:
                    with self.subTest(a=a, b=b):
                        result = await client.call_tool("add", {"a": a, "b": b})
                        self.assertFalse(result.is_error)
                        self.assertEqual(len(result.content), 1)
                        self.assertIsInstance(result.content[0], TextContent)
                        self.assertEqual(result.content[0].text, expected)

    async def test_add_invalid_inputs(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                self.assertEqual(client.protocol_version, PROTOCOL_VERSION)
                for arguments, detail in [
                    ({}, '"/a": is required; "/b": is required'),
                    ({"a": "private-value", "b": 3}, '"/a": expected integer'),
                    ({"a": 2, "b": 3, "extra": True}, '"/extra": is not allowed'),
                    ({"a": 2.5, "b": 3}, '"/a": expected integer'),
                    ({"a": True, "b": 3}, '"/a": expected integer'),
                    ({"a": None, "b": 3}, '"/a": expected integer'),
                ]:
                    with self.subTest(arguments=arguments):
                        result = await client.call_tool("add", arguments)
                        self.assertTrue(result.is_error)
                        self.assertEqual(len(result.content), 1)
                        self.assertTrue(all(isinstance(item, TextContent) for item in result.content))
                        self.assertEqual([item.text for item in result.content], [
                            "Tool arguments do not match the input schema. " + detail,
                        ])


    async def test_count_reply_and_stream(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                for count in (1, 3):
                    updates = []

                    async def on_progress(progress, total, message):
                        updates.append((progress, total, message))

                    result = await client.call_tool(
                        "count", {"to": count}, progress_callback=on_progress
                    )
                    self.assertFalse(result.is_error)
                    self.assertEqual(result.content[0].text, str(count))
                    expected = [] if count == 1 else [
                        (n, count, f"Counted {n}") for n in range(1, count + 1)
                    ]
                    self.assertEqual(updates, expected)

    async def test_count_without_progress_and_invalid_arguments(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                result = await client.call_tool("count", {"to": 2})
                self.assertFalse(result.is_error)
                self.assertEqual(result.content[0].text, "2")
                for arguments in ({}, {"to": 0}, {"to": 21}, {"to": "3"}):
                    with self.subTest(arguments=arguments):
                        result = await client.call_tool("count", arguments)
                        self.assertTrue(result.is_error)
                        self.assertIn('"/to":', result.content[0].text)


if __name__ == "__main__":
    unittest.main()
