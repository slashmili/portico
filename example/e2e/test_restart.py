"""Real VM restarts: saved forms must depend on the key, not the verifier override."""

import asyncio
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

from mcp import Client
from mcp.types import ElicitResult


@contextmanager
def fresh_server(key):
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="restart-", dir=root / "e2e") as temporary:
        ready = Path(temporary) / "port"
        log = Path(temporary) / "server.log"
        environment = dict(os.environ, MIX_ENV="test", PORTICO_E2E_READY_FILE=str(ready))
        environment.pop("ELICITATION_KEY", None)
        if key is not None:
            environment["ELICITATION_KEY"] = key
        with log.open("w") as output:
            process = subprocess.Popen(
                ["mix", "run", "e2e/restart_server.exs"], cwd=root,
                env=environment, stdout=output, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    if ready.exists() and (port := ready.read_text().strip()):
                        yield f"http://127.0.0.1:{int(port)}/mcp"
                        return
                    time.sleep(0.05)
                raise RuntimeError("Restart test server did not start:\n" + log.read_text()[-8000:])
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)


def submit(url, tool, token):
    payload = {
        "jsonrpc": "2.0", "id": 22, "method": "tools/call",
        "params": {
            "name": tool, "arguments": {}, "requestState": token,
            "inputResponses": {"form": {"action": "accept", "content": {"name": "Ada"}}},
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {"elicitation": {"form": {}}},
            },
        },
    }
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "Mcp-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": tool,
    })
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.loads(response.read())


class RestartTest(unittest.TestCase):
    async def pending_forms(self, url):
        async def on_form(context, params):
            return ElicitResult(action="cancel")

        async with Client(url, read_timeout_seconds=10, elicitation_callback=on_form) as client:
            tokens = {}
            for tool in ("default", "override"):
                pending = await client.session.call_tool(tool, {}, allow_input_required=True)
                self.assertEqual(pending.result_type, "input_required")
                tokens[tool] = pending.request_state
            return tokens

    def test_new_vm_with_ephemeral_key_rejects_both_saved_forms(self):
        with fresh_server(None) as first:
            tokens = asyncio.run(self.pending_forms(first))
            for tool, token in tokens.items():
                self.assertEqual(submit(first, tool, token)[0], 200)
        with fresh_server(None) as second:
            for tool, token in tokens.items():
                with self.subTest(verifier=tool):
                    status, body = submit(second, tool, token)
                    self.assertEqual(status, 400)
                    self.assertEqual(body["error"]["code"], -32602)
            # Fresh forms still work after the restart.
            for tool, token in asyncio.run(self.pending_forms(second)).items():
                self.assertEqual(submit(second, tool, token)[0], 200)

    def test_new_vm_with_shared_key_accepts_both_saved_forms(self):
        key = "restart-test-only-key-" * 3
        with fresh_server(key) as first:
            tokens = asyncio.run(self.pending_forms(first))
        with fresh_server(key) as second:
            for tool, token in tokens.items():
                with self.subTest(verifier=tool):
                    status, body = submit(second, tool, token)
                    self.assertEqual(status, 200)
                    self.assertEqual(body["result"]["content"][0]["text"], "Hello, Ada!")
