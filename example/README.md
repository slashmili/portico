# Portico example

A standalone Elixir application exposing `add` and `count` MCP tools over real HTTP.
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

From this directory, use Python 3.11 or newer. No manually running server is
needed for the default test command:

```sh
mix deps.get
python3 -m venv .venv
.venv/bin/python -m pip install -r e2e/requirements.txt
.venv/bin/python -m unittest discover -s e2e -v
```

The suite pins the [official MCP SDK](https://pypi.org/project/mcp/2.2.0/) to
`2.2.0`. It checks discovery, the advertised tools/schemas, and `add` with positive,
negative, and zero inputs, plus expected errors for invalid inputs, through the
SDK over HTTP. It also checks `count` with immediate replies, streamed progress,
completion without a progress callback, and invalid arguments. Each connection asserts
protocol version `2026-07-28`; fallback to another version fails the test.
No mocks or substituted protocol messages are used. By default, the suite starts
a freshly compiled Elixir server on an OS-assigned loopback port and stops it
afterward, including when tests fail. Startup and requests have bounded timeouts.
This avoids testing an older app process after editing the source.

To test your own running server instead, set the endpoint explicitly. Restart
that server after code changes; the suite does not manage an external server:

```sh
MCP_URL=http://127.0.0.1:4001/mcp .venv/bin/python -m unittest discover -s e2e -v
```

When adding a tool to this showcase, add its real-client tests to `e2e/` too.
Only point the suite at an instance you intend to exercise. Discovery and listing
currently advertise private cache scope with zero TTL (immediately stale).

Tool tests use the library's shipped helper without a listener. A separate
disconnect test starts an ephemeral Bandit listener and verifies that closing
a real HTTP connection stops a silent worker:

```sh
mix test --warnings-as-errors
mix format --check-formatted
```

## Files to explore

- `lib/portico_example/mcp.ex` — the route-like tool declarations.
- `lib/portico_example/tools/add.ex` — raw JSON Schema and the tool callback.
- `lib/portico_example/tools/count.ex` — immediate replies and streaming callbacks.
- `lib/portico_example/router.ex` — mounts Portico at `/mcp`.
- `lib/portico_example/application.ex` — starts the listener under supervision.
- `config/runtime.exs` — port, Origin allowlist, and no listener during unit tests.
- `test/mcp_test.exs` — `call_tool` and `assert_text`, without parentheses.
- `e2e/test_mcp.py` — real Python client interoperability tests.

This is the first manual-testing checkpoint. Discovery, listing, and completed
text tool calls and progress streams work; elicitation is still pending. Schemas are
checked at compile time as Draft 2020-12, normalized, and advertised. Arguments
are validated before callbacks run. The `add` callback only performs arithmetic;
Portico handles missing fields, wrong types, and extra properties.
Custom `Mcp-Param` annotations are also pending.


## Expected tool failures

Completed callbacks return `{:ok, %Portico.Result{}}`. The request is passed in for
context but is not returned. `:ok` means the callback produced a result;
`result.is_error` says whether the tool succeeded. For an expected failure:

```elixir
{:ok, Portico.Result.error("Provide exactly two integers, a and b.")}
```

After restarting the example, call `add` with `{"a": "2", "b": 3}` to see a
schema error:

```text
Tool arguments do not match the input schema. "/a": expected integer
```

Missing arguments report `"/a": is required; "/b": is required`. Paths use
JSON-quoted JSON Pointers: nested array fields look like `"/items/0/name"`, and
`""` identifies the root. Messages omit submitted values. Other constraints
identify their schema keyword, for example `does not satisfy minimum`.
The callback will not run. The response is HTTP 200 with a completed result and `isError: true`; the Python
client exposes this as `result.is_error`. Unknown tools and malformed protocol
requests still return JSON-RPC errors. Unexpected callback exceptions remain
sanitized internal errors. Local tests can use `assert result.is_error` alongside
`assert_text result, "..."`.


## Build a result incrementally

`text/2` appends content in order and `put_error/2` sets or clears the error flag:

```elixir
result =
  %Portico.Result{}
  |> Portico.Result.text("Provide exactly two integers, a and b.")
  |> Portico.Result.text("Example: a=2, b=3.")
  |> Portico.Result.put_error(true)

{:ok, result}
```

This pipeline is useful for application failures that need several messages.
Schema failures are handled automatically before the callback. `Result.text/1`
and `Result.error/1` remain shortcuts for a single text item. All helpers return a
new result without modifying the original.


## Schema declarations

Keep schemas as ordinary maps. Portico normalizes atom keys to strings and checks
schema validity at compilation. Schema values use JSON types (for example,
`type: "integer"` and `required: ["a"]`). Ambiguous atom/string duplicate keys,
non-JSON values, invalid keywords, unsupported dialects, and unresolved references
fail compilation. Local references work without network fetching. `format`
remains an annotation. JSV is behind an internal Portico boundary and is not part
of the tool-author API; it can be replaced without rewriting tool declarations.

The Python listing test also checks the advertised schema with an independent
Draft 2020-12 validator. These targeted tests are not full conformance testing.


Argument validation preserves submitted values and does not insert defaults.
JSON Schema treats `2.0` as an integer; the example accepts it and formats the sum
as an integer. Fractional values such as `2.5`, numeric strings, booleans, and null
are rejected for this tool. Python E2E checks these cases. Error messages identify field paths and reasons without echoing argument values.


## Choose a reply or a progress stream

The `count` tool returns a normal reply for `to: 1`. Larger counts return
`{:noreply, data, :stream}` and run `handle_stream/2` in a request-owned task:

```elixir
@impl true
def call(%{"to" => to}, _request) when to == 1,
  do: {:ok, Portico.Result.text("1")}

def call(%{"to" => to}, _request), do: {:noreply, trunc(to), :stream}

@impl true
def handle_stream(to, stream) do
  for current <- 1..to do
    Process.sleep(100)
    Portico.Stream.send(stream, {:progress, current, total: to, message: "Counted #{current}"})
  end

  {:ok, Portico.Result.text(Integer.to_string(to))}
end
```

The original request and its assigns are available in `stream.request`.
`Portico.Stream.send/2` returns `:ok` or `{:error, reason}`. It validates numeric, increasing progress
and sends updates only if the client supplied a progress token. `total:` and
`message:` are optional. Invalid updates are rejected without being sent or
ending the stream. For example, repeating a progress value returns
`{:error, :non_increasing_progress}`. Handle a rejection explicitly when needed:

```elixir
case Portico.Stream.send(stream, {:progress, current, total: to}) do
  :ok -> {:ok, Portico.Result.text("Finished")}
  {:error, _reason} -> {:ok, Portico.Result.error("Could not report progress")}
end
```

The callback always finishes with `{:ok, result}`;
`Portico.Result.error/1` works here too.

After restarting the example, watch the SSE events with curl:

```sh
curl -N http://127.0.0.1:4000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Mcp-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/call' \
  -H 'Mcp-Name: count' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"count","arguments":{"to":5},"_meta":{
      "io.modelcontextprotocol/protocolVersion":"2026-07-28",
      "io.modelcontextprotocol/clientCapabilities":{},"progressToken":"count-1"
    }}}'
```

Try `"to":1` for a JSON reply. Omit `progressToken` to get an SSE stream containing
only comments and the final result. This streams progress, not partial result text.

Portico stops the callback task on disconnect detection or timeout. It writes
SSE heartbeat comments every second during silent work, allowing disconnects
to be detected even when the callback never reports progress. Detection timing
depends on the server and network. The Plug option `stream_timeout:` defaults to
30,000 milliseconds; the host HTTP server controls network write timeouts.
Exceptions after streaming starts produce a generic JSON-RPC error event; the
already-sent HTTP status remains 200. Cancellation cannot roll back side effects
or stop detached processes created by application code.

In ExUnit, `call_tool` still returns the final Result. Collect progress with:

```elixir
result = call_tool mcp, "count", %{"to" => 3},
  on_progress: fn update -> send(self(), {:progress, update}) end,
  timeout: 5_000

assert_text result, "3"
assert_received {:progress, %{progress: 1, total: 3}}
```

The helper's streaming timeout defaults to 5,000 milliseconds and stops unfinished
work before raising. Tool exceptions propagate in tests. `handle_stream/2` is
optional for tools that always return normal replies.
