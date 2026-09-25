"""Real HTTP checks with an owned Elixir server, or an explicit MCP_URL."""

import asyncio
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

import json
import urllib.request
import urllib.error

from jsonschema import Draft202012Validator
from mcp import Client
from mcp.types import TextContent, ElicitResult

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
                self.assertEqual([tool.name for tool in listing.tools], ["add", "choose_color", "choose_colors", "count", "greet"])
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

    async def test_choose_colors(self):
        for colors in [["red"], ["red", "blue"], ["blue", "green"]]:
            with self.subTest(colors=colors):
                async def on_form(context, params):
                    field = params.requested_schema["properties"]["colors"]
                    self.assertEqual(field["items"], {"type": "string", "enum": ["red", "green", "blue"]})
                    self.assertEqual((field["minItems"], field["maxItems"]), (1, 2))
                    return ElicitResult(action="accept", content={"colors": colors})

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("choose_colors", {})
                        self.assertFalse(result.is_error)
                        self.assertEqual(result.content[0].text, f"You chose {', '.join(colors)}.")

    async def test_choose_colors_reasks_for_invalid_selection(self):
        for invalid in [[], ["purple"], ["red", "green", "blue"], "red"]:
            with self.subTest(invalid=invalid):
                answers = iter([invalid, ["green", "blue"]])
                seen = []

                async def on_form(context, params):
                    seen.append(params)
                    return ElicitResult(action="accept", content={"colors": next(answers)})

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("choose_colors", {})
                        self.assertEqual(result.content[0].text, "You chose green, blue.")
                        self.assertEqual(len(seen), 2)

    async def test_choose_colors_decline_cancel(self):
        for action, expected in [("decline", "No colors selected."), ("cancel", "Cancelled.")]:
            with self.subTest(action=action):
                async def on_form(context, params):
                    return ElicitResult(action=action)

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("choose_colors", {})
                        self.assertEqual(result.content[0].text, expected)
                        self.assertEqual(result.is_error, action == "decline")

    async def test_choose_color(self):
        for color in ["#ff0000", "#00ff00", "#0000ff"]:
            with self.subTest(color=color):
                async def on_form(context, params):
                    field = params.requested_schema["properties"]["color"]
                    self.assertEqual(field["oneOf"], [
                        {"const": "#ff0000", "title": "Red"},
                        {"const": "#00ff00", "title": "Green"},
                        {"const": "#0000ff", "title": "Blue"},
                    ])
                    self.assertEqual(field["title"], "Choose a color")
                    return ElicitResult(action="accept", content={"color": color})

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("choose_color", {})
                        self.assertFalse(result.is_error)
                        self.assertEqual(result.content[0].text, f"You chose {color}.")

    async def test_choose_color_rejects_unknown_choice(self):
        answers = iter(["purple", "Red", "#00ff00"])
        seen = []

        async def on_form(context, params):
            seen.append(params)
            return ElicitResult(action="accept", content={"color": next(answers)})

        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                result = await client.call_tool("choose_color", {})
                self.assertEqual(result.content[0].text, "You chose #00ff00.")
                self.assertEqual(len(seen), 3)

    async def test_choose_color_decline_cancel(self):
        for action, expected in [("decline", "No color selected."), ("cancel", "Cancelled.")]:
            with self.subTest(action=action):
                async def on_form(context, params):
                    return ElicitResult(action=action)

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("choose_color", {})
                        self.assertEqual(result.content[0].text, expected)
                        self.assertEqual(result.is_error, action == "decline")

    async def test_greet_form_accept_decline_cancel(self):
        for action, expected in [("accept", "Hello, Ada!"), ("decline", "Name declined."), ("cancel", "Cancelled.")]:
            with self.subTest(action=action):
                seen = []

                async def on_form(context, params):
                    seen.append(params)
                    self.assertEqual(params.message, "What is your name?")
                    self.assertEqual(params.requested_schema["required"], ["name"])
                    return ElicitResult(action=action, content={"name": "Ada"} if action == "accept" else None)

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("greet", {})
                        self.assertEqual(result.content[0].text, expected)
                        self.assertEqual(len(seen), 1)

    async def test_greet_stream_then_form(self):
        for action, expected in [("accept", "Hello, Ada!"), ("decline", "Name declined."), ("cancel", "Cancelled.")]:
            with self.subTest(action=action):
                events = []

                async def on_progress(progress, total, message):
                    events.append(("progress", progress, total, message))

                async def on_form(context, params):
                    events.append(("form", params.message))
                    return ElicitResult(action=action, content={"name": "Ada"} if action == "accept" else None)

                async with asyncio.timeout(15):
                    async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                        result = await client.call_tool("greet", {"stream": True}, progress_callback=on_progress)
                        self.assertEqual(result.content[0].text, expected)
                        self.assertEqual(events, [
                            ("progress", 1, 1, "Ready to ask your name"),
                            ("form", "What is your name?"),
                        ])

    async def test_greet_stream_without_progress_callback(self):
        async def on_form(context, params):
            return ElicitResult(action="accept", content={"name": "Ada"})

        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                result = await client.call_tool("greet", {"stream": True})
                self.assertEqual(result.content[0].text, "Hello, Ada!")

    async def test_greet_without_form_support(self):
        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10) as client:
                for arguments in ({}, {"stream": True}):
                    result = await client.call_tool("greet", arguments)
                    self.assertTrue(result.is_error)
                    self.assertIn("does not support form elicitation", result.content[0].text)

    async def test_greet_reasks_for_invalid_content(self):
        answers = iter([{"name": ""}, {"name": "Ada"}])
        seen = []

        async def on_form(context, params):
            seen.append(params)
            return ElicitResult(action="accept", content=next(answers))

        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                result = await client.call_tool("greet", {})
                self.assertEqual(result.content[0].text, "Hello, Ada!")
                self.assertEqual(len(seen), 2)

    async def test_greet_tampered_state_is_rejected(self):
        async def on_form(context, params):
            return ElicitResult(action="cancel")

        async with asyncio.timeout(15):
            async with Client(URL, read_timeout_seconds=10, elicitation_callback=on_form) as client:
                pending = await client.session.call_tool("greet", {}, allow_input_required=True)
                self.assertEqual(pending.result_type, "input_required")
                payload = {
                    "jsonrpc": "2.0", "id": 22, "method": "tools/call",
                    "params": {
                        "name": "greet", "arguments": {},
                        "requestState": pending.request_state + "x",
                        "inputResponses": {"form": {"action": "cancel"}},
                        "_meta": {
                            "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
                            "io.modelcontextprotocol/clientCapabilities": {"elicitation": {"form": {}}},
                        },
                    },
                }

                def post_tampered():
                    request = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json, text/event-stream",
                        "Mcp-Protocol-Version": PROTOCOL_VERSION,
                        "Mcp-Method": "tools/call", "Mcp-Name": "greet",
                    })
                    try:
                        response = urllib.request.urlopen(request, timeout=10)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        return response.status, response.read().decode()

                status, body = await asyncio.to_thread(post_tampered)
                self.assertEqual(status, 400)
                self.assertEqual(json.loads(body)["error"]["code"], -32602)
                self.assertNotIn(pending.request_state, body)



if __name__ == "__main__":
    unittest.main()
