# Portico example

A standalone Elixir application exposing one MCP tool, `add`, over real HTTP.
It depends on Portico via `path: ".."` and owns its Bandit listener.

## Run

Use Elixir 1.20 / OTP 29. From this directory:

```sh
mix deps.get
mix run --no-halt
```

Connect your MCP client using Streamable HTTP at **http://127.0.0.1:4000/mcp**.
The client must support MCP **2026-07-28**; older `initialize`-based clients
are not supported. Try `add` with `{"a": 2, "b": 3}`; the text result is `5`.
Stop the server with Ctrl+C (then `a` if the Erlang break menu appears).

The router runs `Plug.Logger` before routing, logging each request at info level:

```text
[info] POST /mcp
[info] Sent 200 in 2ms
```

Portico logs the decoded MCP method, request ID, and parameters at debug level,
including tool arguments. Visibility follows the application's Logger level:

```text
[debug] Processing MCP "tools/call" (id=1)
  Parameters: %{"_meta" => ..., "arguments" => %{"a" => 2, "b" => 3}, "name" => "add"}
```

Debug logging is explicitly enabled in development. Set the Logger level to
`config :logger, level: :info` to keep only the HTTP summaries. There is no
separate logging option on `Portico.Plug`.
Portico logs both raw and already-parsed requests; no extra parser is needed.
Results, headers, and assigns are not logged.

Parameter keys containing `password`, `secret`, `token`, `authorization`, or
`api_key` are redacted recursively, ignoring case. Extend these defaults with
`filter_parameters: ["email", "credential"]` in the Plug options. Filtering only
changes log output; tool callbacks receive the original arguments.
Restart `mix run --no-halt` after code changes to load them.

The listener binds only to loopback. To use another port:

```sh
PORT=4001 mix run --no-halt
```

Requests without an Origin header are accepted. If your client sends Origin,
allow its exact value explicitly (comma-separated for multiple values):

```sh
ALLOWED_ORIGINS=http://localhost:6274 mix run --no-halt
```

Use the Origin your client actually sends; the value above is just an example.
This configures request validation, not browser CORS handling. The example has
no authentication or CORS preflight support.

## Test with the official Python MCP client

Keep the Elixir server running in one terminal. In a second terminal, from this
directory, use Python 3.11 or newer:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r e2e/requirements.txt
.venv/bin/python -m unittest discover -s e2e -v
```

The suite pins the [official MCP SDK](https://pypi.org/project/mcp/2.2.0/) to
`2.2.0`. It checks discovery, the advertised tool/schema, and `add` with positive,
negative, and zero inputs, plus expected errors for invalid inputs, through the
SDK over HTTP. Each connection asserts
protocol version `2026-07-28`; fallback to another version fails the test.
No mocks or substituted protocol messages are used. Tests fail if the server is
unavailable and have bounded timeouts.

For another port, set the endpoint explicitly:

```sh
MCP_URL=http://127.0.0.1:4001/mcp .venv/bin/python -m unittest discover -s e2e -v
```

When adding a tool to this showcase, add its real-client tests to `e2e/` too.
Only point the suite at an instance you intend to exercise. Discovery and listing
currently advertise private cache scope with zero TTL (immediately stale).

The local Elixir test uses the library's shipped helper and needs no listener:

```sh
mix test --warnings-as-errors
mix format --check-formatted
```

## Files to explore

- `lib/portico_example/mcp.ex` — the route-like tool declarations.
- `lib/portico_example/tools/add.ex` — raw JSON Schema and the tool callback.
- `lib/portico_example/router.ex` — mounts Portico at `/mcp`.
- `lib/portico_example/application.ex` — starts the listener under supervision.
- `config/runtime.exs` — port, Origin allowlist, and no listener during unit tests.
- `test/mcp_test.exs` — `call_tool` and `assert_text`, without parentheses.
- `e2e/test_mcp.py` — real Python client interoperability tests.

This is the first manual-testing checkpoint. Discovery, listing, and completed
text tool calls work; streaming and elicitation are still pending. Schemas are
advertised but not yet validated by Portico. The `add` callback explicitly checks
for exactly two integer arguments and returns `Portico.Result.error/1` for invalid
inputs. This is application validation, not a general JSON Schema validator.
Custom `Mcp-Param` annotations are also pending.


## Expected tool failures

Callbacks always return `{:ok, %Portico.Result{}}`. The request is passed in for
context but is not returned. `:ok` means the callback produced a result;
`result.is_error` says whether the tool succeeded. For an expected failure:

```elixir
{:ok, Portico.Result.error("Provide exactly two integers, a and b.")}
```

After restarting the example, call `add` with `{"a": "2", "b": 3}` to try it.
The response is HTTP 200 with a completed result and `isError: true`; the Python
client exposes this as `result.is_error`. Unknown tools and malformed protocol
requests still return JSON-RPC errors. Unexpected callback exceptions remain
sanitized internal errors. Local tests can use `assert result.is_error` alongside
`assert_text result, "..."`.
