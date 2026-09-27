"""Opt-in HTTP size probe; continuation regression intentionally fails.

Run: .venv/bin/python e2e/probe_body_limits.py -v
Owns a loopback Bandit server. At most 16 MiB/request. Never prints tokens.
"""
import copy
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


class BodyLimitProbe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="portico-body-limit-")
        cls.addClassCleanup(temporary.cleanup)
        ready = Path(temporary.name) / "port"
        log = Path(temporary.name) / "server.log"
        output = log.open("w")
        cls.addClassCleanup(output.close)
        process = subprocess.Popen(
            ["mix", "run", "e2e/body_limit_server.exs"],
            cwd=Path(__file__).resolve().parents[1],
            env=dict(os.environ, MIX_ENV="test", PORTICO_BODY_LIMIT_READY_FILE=str(ready)),
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
        )
        def stop():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        cls.addClassCleanup(stop)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if process.poll() is not None:
                break
            if ready.exists() and (port := ready.read_text().strip()):
                cls.port = int(port)
                return
            time.sleep(0.05)
        raise RuntimeError("Probe server did not start:\n" + log.read_text()[-6000:])

    @staticmethod
    def message(payload="", form=False):
        return {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "probe", "arguments": {"payload": payload, "form": form},
            "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientCapabilities": {"elicitation": {"form": {}}}},
        }}

    @staticmethod
    def encode(message):
        return json.dumps(message, separators=(",", ":"), ensure_ascii=True).encode()

    def sized_body(self, size):
        return self.encode(self.message("x" * (size - len(self.encode(self.message())))))

    def send(self, path, body, method="POST"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        try:
            conn.request(method, path, body, headers={
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                "Mcp-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "probe",
            })
            response = conn.getresponse()
            try:
                return response.status, response.read()
            except ConnectionResetError:
                print(f"\n{path}: HTTP {response.status} received, connection reset while reading response", flush=True)
                return response.status, b""
        except (ConnectionResetError, BrokenPipeError, http.client.RemoteDisconnected):
            print(f"\n{path}: connection closed before HTTP status (oversized body still being sent)", flush=True)
            return 0, b""
        finally:
            conn.close()

    def tearDown(self):
        self.assertEqual(self.send("/health", b"", "GET"), (200, b"alive"))

    def test_portico_exact_raw_body_boundary(self):
        for size in (999_999, 1_000_000, 1_000_001):
            status, body = self.send("/mcp", self.sized_body(size))
            print(f"\nPortico raw: body={size:,} bytes -> HTTP {status}", flush=True)
            self.assertEqual(status, 200 if size <= 1_000_000 else 413)
            if status == 200:
                self.assertIn("result", json.loads(body))

    def test_plug_parser_and_bandit_reading(self):
        for size in (1_000_001, 8_000_000, 8_000_001, 8_100_000):
            status, body = self.send("/parsed", self.sized_body(size))
            print(f"\nPlug.Parsers default: body={size:,} bytes -> HTTP {status}", flush=True)
            if size in (1_000_001, 8_000_000):
                self.assertEqual(status, 200)
                self.assertIn("result", json.loads(body))
            elif size == 8_100_000:
                self.assertIn(status, (413, 0))
            else:
                self.assertIn(status, (200, 413, 0))

    def test_bandit_repeated_reads(self):
        size = 16 * 1024 * 1024
        status, body = self.send("/raw", b"x" * size)
        print(f"\nBandit + repeated Plug.read_body: body={size:,} bytes -> HTTP {status}", flush=True)
        self.assertEqual((status, body), (200, str(size).encode()))

    def test_accepted_form_can_be_submitted(self):
        initial = self.message("x" * 600_000, form=True)
        initial_body = self.encode(initial)
        status, body = self.send("/mcp", initial_body)
        self.assertEqual(status, 200)
        pending = json.loads(body)["result"]
        token = pending["requestState"]
        retry = copy.deepcopy(initial)
        retry["params"].update(requestState=token, inputResponses={
            "form": {"action": "accept", "content": {"yes": True}}})
        retry_body = self.encode(retry)
        retry_status, _ = self.send("/mcp", retry_body)
        larger_status, larger_body = self.send("/larger", retry_body)
        print(f"\nContinuation: initial={len(initial_body):,} bytes -> HTTP {status}; "
              f"token={len(token.encode()):,} bytes; retry={len(retry_body):,} bytes "
              f"-> HTTP {retry_status}; same retry with 4 MB limit -> HTTP {larger_status}", flush=True)
        self.assertEqual(larger_status, 200)
        self.assertEqual(json.loads(larger_body)["result"]["content"][0]["text"], "Resumed")
        # Intentionally red: valid input creates an unusable continuation.
        self.assertEqual(retry_status, 200,
                         "Accepted form cannot resume: generated continuation exceeds the endpoint body limit")


if __name__ == "__main__":
    unittest.main()
