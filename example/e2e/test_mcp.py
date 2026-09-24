"""Real HTTP checks against the running Elixir example (no mocks)."""

import asyncio
import os
import unittest

from mcp import Client
from mcp.types import TextContent

URL = os.environ.get("MCP_URL", "http://127.0.0.1:4000/mcp")
PROTOCOL_VERSION = "2026-07-28"


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
                self.assertEqual([tool.name for tool in listing.tools], ["add"])
                self.assertIsNone(listing.next_cursor)
                self.assertEqual(listing.cache_scope, "private")
                self.assertEqual(listing.ttl_ms, 0)
                tool = listing.tools[0]
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
                for a, b, expected in [(2, 3, "5"), (-4, 2, "-2"), (0, 0, "0")]:
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
                for arguments in [{}, {"a": "2", "b": 3}, {"a": 2, "b": 3, "extra": True}]:
                    with self.subTest(arguments=arguments):
                        result = await client.call_tool("add", arguments)
                        self.assertTrue(result.is_error)
                        self.assertEqual(len(result.content), 1)
                        self.assertIsInstance(result.content[0], TextContent)
                        self.assertEqual(result.content[0].text, "Provide exactly two integers, a and b.")


if __name__ == "__main__":
    unittest.main()
