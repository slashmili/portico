# Portico example

A standalone Elixir application demonstrating tools, streaming, forms, and structured results over HTTP.
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
The optional request metadata field `io.modelcontextprotocol/logLevel` accepts
`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, or `emergency`.
Invalid values return HTTP 400 / JSON-RPC -32602. This field does not change the
application's Logger level or enable MCP log notifications in Portico.
Portico logs both raw and already-parsed requests; no extra parser is needed.
Results, headers, and assigns are not logged.

Parameter keys containing `password`, `secret`, `token`, `authorization`,
`api_key`, or `requeststate` are redacted recursively, ignoring case. Extend these
defaults with
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
no MCP OAuth or CORS preflight support. The `approve_report` showcase uses fixed
local demo logins solely to demonstrate binding browser completion to an MCP caller.

## Structured results

Call `summarize` with `{"numbers": [2, 3, -1]}`. It returns
`structuredContent: {"count": 3, "sum": 4}` and a text item containing the same JSON.
An empty list returns zero for both values. The tool uses:

```elixir
{:ok, result} = Portico.Result.structured(%{count: count, sum: sum})
{:ok, result}
```

`result.structured_content` exposes the normalized data in Elixir tests. Atom map
keys become strings recursively. JSON arrays, scalars and null are supported too;
unsupported values return `{:error, :invalid_structured_content}`. Use `case` when
that error should be recoverable. The tool declares:

```elixir
output_schema: %{
  type: "object",
  properties: %{count: %{type: "integer", minimum: 0}, sum: %{type: "integer"}},
  required: ["count", "sum"],
  additionalProperties: false
}
```

The declaration is checked at compilation and advertised as `outputSchema`.
Portico requires every successful completed result to contain structured data
matching it, without casts or defaults. A missing field or wrong type returns
`{:error, :invalid_output}` in Elixir helpers and a generic internal error over
HTTP. Streamed results and form continuations follow the same rule. Expected
`is_error: true` results, including input validation errors, bypass the output
schema. The Python tests validate the advertised schema and successful outputs.

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
- `lib/portico_example/tools/greet.ex` — form replies and custom verification.
- `lib/portico_example/tools/choose_color.ex` — labeled single-choice forms.
- `lib/portico_example/tools/choose_colors.ex` — multiple-choice forms.
- `lib/portico_example/tools/summarize.ex` — structured JSON results.
- `lib/portico_example/router.ex` — mounts Portico at `/mcp`.
- `lib/portico_example/application.ex` — starts the listener under supervision.
- `config/runtime.exs` — port, Origin allowlist, and no listener during unit tests.
- `test/mcp_test.exs` — `call_tool` and `assert_text`, without parentheses.
- `e2e/test_mcp.py` — real Python client interoperability tests.

Discovery, listing, text and structured results, progress streams, and form
elicitation are supported. Schemas are checked at compile time as Draft 2020-12,
normalized, and advertised. Arguments are validated before callbacks run. The `add` callback only performs arithmetic;
Portico handles missing fields, wrong types, and extra properties.
Custom `x-mcp-header` annotations are rejected at compilation.


## Expected tool failures

Completed callbacks return `{:ok, %Portico.Result{}}`. The request is passed in for
context but is not returned. `:ok` means the callback produced a result;
`result.is_error` says whether the tool succeeded. For an expected failure:

```elixir
{:ok, result} = Portico.Result.error("Provide exactly two integers, a and b.")
{:ok, result}
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


Callback failures that cannot produce a result may return `{:error, reason}`.
The test helper preserves that reason for both immediate and streaming calls.
HTTP logs the reason server-side and sends a generic internal error (HTTP 500
for an immediate reply, or a final JSON-RPC error inside an already-open SSE
response). Use `Result.error/1` for expected, client-visible tool failures.
Avoid secrets in callback error reasons because they appear in server logs.


## Build a result incrementally

`text/2` appends content in order and `put_error/2` sets or clears the error flag:

```elixir
{:ok, result} =
  %Portico.Result{}
  |> Portico.Result.text("Provide exactly two integers, a and b.")
  |> Portico.Result.text("Example: a=2, b=3.")
  |> Portico.Result.put_error(true)

{:ok, result}
```

This pipeline is useful for application failures that need several messages.
Schema failures are handled automatically before the callback. `Result.text/1`
and `Result.error/1` remain shortcuts for a single text item. All helpers return a
new result in `{:ok, result}` without modifying the original. Invalid input returns
`{:error, reason}` and pipelines preserve that error. Match `{:ok, result}`
explicitly before returning `{:ok, result}` from the callback. The match asserts
successful construction and raises `MatchError` if the helper returns an error;
use `case` when you need to recover from a construction failure.


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
def call(%{"to" => to}, _request) when to == 1 do
  {:ok, result} = Portico.Result.text("1")
  {:ok, result}
end

def call(%{"to" => to}, _request), do: {:noreply, trunc(to), :stream}

@impl true
def handle_stream(to, stream) do
  for current <- 1..to do
    Process.sleep(100)
    Portico.Stream.send(stream, {:progress, current, total: to, message: "Counted #{current}"})
  end

  {:ok, result} = Portico.Result.text(Integer.to_string(to))
  {:ok, result}
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
  :ok ->
    {:ok, result} = Portico.Result.text("Finished")
    {:ok, result}

  {:error, _reason} ->
    {:ok, result} = Portico.Result.error("Could not report progress")
    {:ok, result}
end
```

The callback finishes with `{:ok, result}` or `{:error, reason}`;
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

In ExUnit, `call_tool` returns `{:ok, result}` or `{:error, reason}`. Collect progress with:

```elixir
{:ok, result} = call_tool mcp, "count", %{"to" => 3},
  on_progress: fn update -> send(self(), {:progress, update}) end,
  timeout: 5_000

assert_text result, "3"
assert_received {:progress, %{progress: 1, total: 3}}
```

The helper's streaming timeout defaults to 5,000 milliseconds and stops unfinished
work before returning `{:error, :timeout}`. Application exceptions propagate in tests. `handle_stream/2` is
optional for tools that always return normal replies.


## Ask for a name with a form

The `greet` tool demonstrates form elicitation. Use an MCP client supporting
2026-07-28 form elicitation; it displays the form and retries the tool with the
answer. The Python E2E suite exercises accept, decline, cancel, invalid content,
and tampered state. There is no browser page or waiting server process.

```elixir
use Portico.Tool,
  input_schema: %{type: "object", properties: %{}, additionalProperties: false},
  elicitation_verifier: &__MODULE__.verify_input/2

def call(_arguments, _request) do
  {:ok, form} = Portico.Input.form("What is your name?",
    schema: %{
      type: "object",
      properties: %{name: %{type: "string", minLength: 1}},
      required: ["name"]
    })

  {:ok, form, "greet:v1"}
end

def verify_input(token, request) do
  with {:ok, state} <- Portico.Elicitation.verify(token, request) do
    if state == "greet:v1", do: {:ok, state}, else: {:error, :invalid_greeting_state}
  end
end

def handle_input({:accept, %{"name" => name}}, "greet:v1", _request) do
  {:ok, result} = Portico.Result.text("Hello, #{name}!")
  {:ok, result}
end
```

Also handle `:decline` and `:cancel`; the runnable tool includes both. Omit
`elicitation_verifier:` to use the built-in verifier. A custom function receives
the wire token and fresh request, returning `{:ok, application_state}` or
`{:error, reason}`. It runs only on form replies. Portico always verifies the
protected form envelope and validates accepted content; missing or invalid
answers cause the form to be requested again without running `handle_input/3`.

Configure the library signing key per server at runtime:

```elixir
config :portico, MyApp.MCP,
  elicitation_key: System.fetch_env!("ELICITATION_KEY")
```

Use at least 32 random bytes. The example creates an ephemeral key when
`ELICITATION_KEY` is absent; launching a fresh VM then invalidates pending forms.
`recompile()` or stopping/starting the application inside the same IEx VM retains
the key and pending forms remain valid until expiry. With a stable
`ELICITATION_KEY`, valid forms also survive fresh VM restarts. This behavior is
the same with or without a custom verifier. A stable key shared by instances
allows retries across those instances. Tokens expire
in five minutes and bind the server, tool, original arguments, form, and state.
They are signed, not encrypted or single-use. Do not put secrets in state.
Application-specific identity checks and one-time execution remain application
responsibilities; the custom verifier can enforce identity using fresh assigns.
`requestState` is redacted from Portico's parameter logs.

Form elicitation supports one form at a time with flat string, number, integer,
and boolean fields. Single-choice string enums are also supported. Arrays of string enum choices support multiple selection, with optional labels.
URL elicitation is described below. Multiple simultaneous inputs are not implemented. String `format` remains an annotation, as with
tool schemas. Clients without form capability receive JSON-RPC error `-32021`
(`Missing required client capability`); see the HTTP and streaming behavior below.

Direct tests can use the same retry flow:

```elixir
mcp = %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}}}}
{:ok, form, state} = call_tool mcp, "greet", %{}
{:ok, result} = call_tool mcp, "greet", %{},
  request_state: state,
  input_responses: %{"form" => %{"action" => "accept", "content" => %{"name" => "Ada"}}}
assert_text result, "Hello, Ada!"
```


## Stream progress before asking a form

Call `greet` with `{"stream": true}` to receive progress followed by the name
form. The tool chooses the stream in `call/2` and returns a form from its worker:

```elixir
def call(%{"stream" => true}, _request), do: {:noreply, nil, :stream}

def handle_stream(_data, stream) do
  :ok = Portico.Stream.send(stream, {:progress, 1, total: 1, message: "Ready to ask your name"})
  {:ok, form} = Portico.Input.form("What is your name?",
    schema: %{
      type: "object",
      properties: %{name: %{type: "string", minLength: 1}},
      required: ["name"]
    })
  {:ok, form, "greet:v1"}
end
```

The `input_required` result is the final SSE event. Portico closes the stream
and stops the worker; it does not wait for the user in that process. The client
submits the answer in a new POST with the original arguments and signed state.
The same verifier, schema validation, and `handle_input/3` callbacks apply.
The form is still delivered without a progress token; only progress notifications
are omitted. A client without form capability receives protocol error `-32021` with
`data.requiredCapabilities: {"elicitation": {"form": {}}}`. Normal replies and
form retries use HTTP 400. If streaming has already started, the final SSE event
carries this error within the existing HTTP 200 response. In Elixir tests,
`call_tool` returns `{:error, :form_not_supported}`.


## Choose a color from a list

Call `choose_color` with `{}` to try a single-choice enum form. This is a separate
small example in `lib/portico_example/tools/choose_color.ex`; it uses the default
elicitation verifier and leaves the greeting example unchanged.

```elixir
{:ok, form} = Portico.Input.form("Pick your preferred color.",
  schema: %{
    type: "object",
    properties: %{
      color: %{
        type: "string",
        title: "Choose a color",
        oneOf: [
        %{const: "#ff0000", title: "Red"},
        %{const: "#00ff00", title: "Green"},
        %{const: "#0000ff", title: "Blue"}
      ]
      }
    },
    required: ["color"]
  })

{:ok, form, "choose-color:v1"}
```

The client displays labels such as “Red” and submits the corresponding constant
`"#ff0000"`. Portico validates that value before calling `handle_input/3`; an
unknown value or the label `"Red"` requests the form again.

Use `oneOf` with a nonempty list of `%{const: value, title: label}` choices.
Constants must be unique UTF-8 strings, and titles must be UTF-8 strings. An
optional `default: "#00ff00"` must match a constant. Each choice supports exactly
`const` and `title`; field-level `title` and `description` remain supported.

For choices whose labels and values are identical, plain
`enum: ["red", "green", "blue"]` still works. Use either `enum` or `oneOf`, not
both on the same field. For multiple selection, see `choose_colors` below.


## Choose several colors

Call the separate `choose_colors` tool with `{}` to select one or two colors.
It leaves `choose_color` and `greet` unchanged:

```elixir
colors: %{
  type: "array",
  title: "Choose colors",
  minItems: 1,
  maxItems: 2,
  items: %{
    anyOf: [
      %{const: "#ff0000", title: "Red"},
      %{const: "#00ff00", title: "Green"},
      %{const: "#0000ff", title: "Blue"}
    ]
  }
}
```

The client displays color names; the callback receives constants such as
`["#ff0000", "#0000ff"]` in the client's order.
Unknown choices, too few/many choices, or a scalar value cause Portico to request
the form again before calling `handle_input/3`. Array entries must be strings;
nested arrays and objects are malformed replies. Decline and cancel work as usual.

`minItems` and `maxItems` are optional nonnegative integers; the minimum cannot
exceed the maximum. An optional default must be a list of allowed strings within
those limits. For labeled options, defaults contain constants, not labels. The
`items.anyOf` list must be nonempty, with unique string constants and string titles.
Each choice contains exactly `const` and `title`; use `anyOf` for labeled arrays,
not the `oneOf` used by single-choice fields.

Plain `items: %{type: "string", enum: ["red", "green", "blue"]}` still works.
Nested arrays and `uniqueItems` are not supported; submitted selections are not
deduplicated.

This completes the planned form scope for the first version: primitive fields,
single and multiple selection with optional labels, and supported constraints.
Further form extensions are deferred while we review first-version gaps and
exercise real clients.


## Client information metadata

Optional `clientInfo` fields are validated before tools run. `title`, `description`
and `websiteUrl` must be strings. Each `icons` entry needs a string `src`; optional
`mimeType` is a string, `sizes` is a list of strings, and `theme` is `light` or `dark`.
Unknown fields are preserved. Malformed values return HTTP 400 / JSON-RPC -32602.
These are structural checks, not URI, MIME or size-format validation. Portico does
not fetch icons; client information remains self-reported, not authenticated identity.


Request `_meta` keys are checked against MCP's optional prefix/name syntax:
`com.example/trace` and `traceId` are valid; `bad key` and `/trace` are not.
Empty names are allowed by the protocol. Unknown well-formed keys and their
values are preserved, including future reserved-prefix extension keys. Keys
inside extension values are not interpreted as metadata. Invalid names return
HTTP 400 / JSON-RPC -32602 before tool execution.


Known client capabilities are also checked structurally. `roots` and `sampling`
are objects; sampling's optional `context` and `tools` fields are objects too.
`experimental` and `extensions` map names to settings objects. Extension names
require a prefix, such as `com.example/feature`; experimental names are opaque.
Unknown capabilities and settings are preserved. Valid declarations do not enable
sampling, roots, or extensions in Portico; malformed shapes return HTTP 400 / -32602.


## URL elicitation: approve a report in the browser

The separate `approve_report` tool asks you to review fictional report data on a
browser page and approve it. This demonstrates a browser step in a tool workflow.
The application owns a small supervised store of pending approvals (five-minute
expiry, bounded to 1,000 entries, reset when the application stops). Portico itself
uses signed, stateless continuation tokens.

### Try it with MCP Inspector

Start the example as described above, then launch Inspector in another terminal:

```sh
npx @modelcontextprotocol/inspector \
  --server-url http://127.0.0.1:4000/mcp \
  --transport http \
  --protocol-era modern \
  --header "Authorization: Basic YWxpY2U6YWxpY2UtZGVtbw=="
```

The header authenticates MCP requests as the fixed local demo user **alice**
(password **alice-demo**). It is Basic auth supplied by the example, not MCP
OAuth. The example also accepts **bob / bob-demo** to demonstrate that another
user cannot approve Alice's report. These public credentials are for local tests.

If Inspector is already running, add the custom header `Authorization` with value
`Basic YWxpY2U6YWxpY2UtZGVtbw==` to the server settings and reconnect. Include the
`Basic ` prefix; do not use a Bearer token field. Use Streamable HTTP and the modern
protocol era. See the [Inspector configuration guide](https://github.com/modelcontextprotocol/inspector/blob/main/docs/mcp-server-configuration.md).

1. Connect to the example in Inspector and call `approve_report` with `{}`.
2. Open the elicitation URL. When the browser asks for credentials, sign in as
   **alice / alice-demo**, matching the MCP caller. The MCP header is not forwarded
   to this browser page; it authenticates separately.
3. Review the sample report and click **Approve report**.
4. Return to Inspector and resume/retry the pending request. The result should
   say **Demo report approved.**

Consent in Inspector means permission to open the browser interaction. Until the
browser POST records approval, retries return the same URL with a fresh signed
continuation. A different demo user cannot view or approve the report. Approval
needs the hidden confirmation token supplied by the authenticated page; a GET
alone never approves anything. Requests without demo authentication get a tool
error; other example tools remain callable as before.

The tool uses the same callback contract:

```elixir
{:ok, input} = Portico.Input.url("Review the report", url: report_url)
{:ok, input, application_state}
```

`handle_input/3` receives `:accept`, `:decline`, or `:cancel`. Its application-state
argument comes from the existing signed continuation verifier. URL answers omit
`content`; direct Elixir tests use:

```elixir
mcp = %{mcp | client_capabilities: %{"elicitation" => %{"url" => %{}}},
              assigns: %{demo_user: "alice"}}
{:ok, input, state} = call_tool mcp, "approve_report", %{}
{:ok, pending_input, _state} = call_tool mcp, "approve_report", %{},
  request_state: state,
  input_responses: %{"url" => %{"action" => "accept"}}
```

Missing URL capability yields JSON-RPC `-32021` with
`requiredCapabilities: {"elicitation": {"url": {}}}`. Empty elicitation capability
only supports forms. The helper returns `{:error, :url_not_supported}`. HTTP uses
400, or a final error within an already-started 200 SSE response.

Portico accepts absolute HTTP/HTTPS URLs without embedded credentials and never
fetches them. Use HTTPS outside local development. Applications must keep secrets
and personal information out of URLs, verify the browser identity against the MCP
caller, and manage completion storage. Do not use a URL as a pre-authenticated
entry to a protected resource. Signed requestState does not authenticate a user.

MCP OAuth support is on the TODO list and is not implemented. It will address
client authorization to the MCP server; the browser step shown here is a separate
application workflow. Production authentication cannot use these fixed demo logins.

Python E2E tests simulate the separate browser GET/POST, check that consent alone
stays pending, reject a different browser user, and test approval, decline,
cancel, missing identity, and missing URL capability. Library tests also cover
streamed URL inputs, malformed replies, mode substitution and token binding.


## Static text resources

The example exposes `company://handbook` as a resource. In Inspector, connect as
usual, open **Resources**, list the available resources and read the handbook.
This does not require the report-approval demo credentials.

The server declares a route alongside its tools:

```elixir
resource "company://handbook", PorticoExample.Resources.Handbook
```

The resource module owns metadata and its callback:

```elixir
defmodule PorticoExample.Resources.Handbook do
  use Portico.Resource,
    name: "handbook",
    description: "A sample company handbook.",
    mime_type: "text/plain"

  @impl true
  def read(_request) do
    {:ok, content} = Portico.Resource.text("Welcome to the company. Ask questions and share what you learn.")
    {:ok, content}
  end
end
```

The read callback receives a fresh `Portico.Request`, with `resource_uri`, server,
client metadata and assigns. A URI routes to a declaration: it does not trigger an
automatic filesystem read or HTTP fetch. Callbacks own data retrieval and access
checks. Listings are static; they do not filter resources by user identity.

Test the same route without an HTTP listener:

```elixir
{:ok, content} = read_resource mcp, "company://handbook"
assert content.uri == "company://handbook"
assert content.mime_type == "text/plain"
assert content.text == "Welcome to the company. Ask questions and share what you learn."
```

The helper also accepts a server module and an optional `assigns:` override.
It returns `{:error, :resource_not_found}` for undeclared URIs, preserves callback
error reasons and lets application exceptions surface in tests. HTTP returns
`-32602` for invalid parameters or unknown resources and sanitized `-32603` for
callback failures. Constructors and invalid helper inputs return error tuples;
invalid declarations fail at compilation.

For a single text or binary item, Portico supplies the concrete requested URI
and declared MIME type. List reads preserve each item's URI and MIME type. Resources are listed in URI order;
listing and reading use private caching with zero TTL. There is no pagination;
cursors are rejected. Subscriptions remain a future slice. Python E2E checks both catalogs, text content, decoded
template variables and missing URI errors.

## Resource templates

A template routes a family of URIs to one resource module:

```elixir
resource_template "company://handbook/{section}", PorticoExample.Resources.HandbookSection
```

The module uses the same `read/1` callback as a static resource:

```elixir
defmodule PorticoExample.Resources.HandbookSection do
  use Portico.Resource,
    name: "handbook-section",
    description: "A generated handbook section heading.",
    mime_type: "text/plain"

  def read(%{resource_params: %{"section" => section}}) do
    {:ok, content} = Portico.Resource.text("Handbook section: #{section}")
    {:ok, content}
  end
end
```

This example generates a heading for any section name. It does not look up a file.
In Inspector, open **Resources**, list templates, choose
`company://handbook/{section}` and supply `leave` for `section`, then read it.
The resulting URI is `company://handbook/leave`.

```elixir
{:ok, content} = read_resource mcp, "company://handbook/caf%C3%A9"
assert content.text == "Handbook section: café"
assert content.uri == "company://handbook/caf%C3%A9"
```

Variables are string-keyed and percent-decoded once in `request.resource_params`.
Static reads have an empty params map. Templates are advertised separately by
`resources/templates/list`; `resources/list` contains only static declarations.

This slice supports simple variables occupying whole path segments. Query,
reserved, exploded, prefix and partial-segment expressions fail at compilation.
Static routes win over templates. Duplicate template shapes fail at compilation;
other overlapping matches return `{:error, :ambiguous_resource}` in helpers and
a sanitized internal error over HTTP. Decoded variables are untrusted application
input: `a%2Fb` becomes `a/b`, so do not turn them into unchecked filesystem paths.


## Binary resources

Read `company://sample` from Inspector's **Resources** tab to try a binary resource.
It contains four fixed bytes and requires no files or authentication.

```elixir
resource "company://sample", PorticoExample.Resources.Sample
```

```elixir
defmodule PorticoExample.Resources.Sample do
  use Portico.Resource,
    name: "sample",
    description: "Four sample bytes.",
    mime_type: "application/octet-stream"

  def read(_request) do
    {:ok, content} = Portico.Resource.blob(<<0, 1, 2, 255>>)
    {:ok, content}
  end
end
```

Pass raw bytes to `Resource.blob/1`, including an empty binary if needed.
Other values return `{:error, :invalid_blob}`. The test helper returns raw bytes:

```elixir
{:ok, content} = read_resource mcp, "company://sample"
assert content.blob == <<0, 1, 2, 255>>
assert content.text == nil
```

Portico encodes those bytes as base64 (`AAEC/w==`) in the protocol's `blob`
field and omits `text`. Do not base64-encode the constructor input yourself.
Each content item must contain exactly one payload: text or blob. Malformed structs return
`{:error, :invalid_resource}` in helpers and a sanitized internal error over HTTP.
Both static and template routes support binary content.


## Multiple contents in one read

Read `company://docs` in Inspector's **Resources** tab to receive two generated
documents. Declare the resource normally:

```elixir
resource "company://docs", PorticoExample.Resources.Documents
```

Its `read/1` returns a list:

```elixir
def read(_request) do
  {:ok, readme} =
    Portico.Resource.text("Welcome",
      uri: "company://docs/readme",
      mime_type: "text/plain"
    )

  {:ok, guide} =
    Portico.Resource.text("# Getting started",
      uri: "company://docs/guide",
      mime_type: "text/markdown"
    )

  {:ok, [readme, guide]}
end
```

`Resource.text/2` and `Resource.blob/2` accept optional `uri:` and `mime_type:`.
Invalid URIs or MIME values return `{:error, :invalid_uri}` or
`{:error, :invalid_mime_type}`; unknown, duplicate or malformed options return
`{:error, :invalid_options}`.

Every list item requires an absolute URI. MIME type is optional per item and
does not inherit the directory's MIME type. Lists may mix text and binary items.
Portico preserves order and rejects the whole read if any item is invalid.
The content URIs identify returned items; they do not automatically register
independently readable routes.

```elixir
{:ok, [readme, guide]} = read_resource mcp, "company://docs"
assert readme.uri == "company://docs/readme"
assert guide.mime_type == "text/markdown"
```

A list callback yields a list in the helper, even with one item. Existing
single-item callbacks still yield one struct with the route's URI and MIME type.
An empty list means an existing resource has no contents; do not use it to
represent a missing resource.


## Resource lookups and missing entries

The `company://policies/{name}` template looks up two fixed policies: `leave`
and `expenses`. In Inspector, list resource templates and read
`company://policies/leave`. Try `company://policies/missing` to see the missing
resource error.

A matching route does not guarantee the requested entry exists. In `read/1`,
return `{:error, :resource_not_found}` when your lookup finds no entry:

```elixir
case Map.fetch(@policies, name) do
  {:ok, text} ->
    {:ok, content} = Portico.Resource.text(text)
    {:ok, content}

  :error ->
    {:error, :resource_not_found}
end
```

The helper preserves the error tuple; MCP receives `-32602` with the message
“Resource not found”. Malformed requests retain “Invalid params”. Other callback
errors remain sanitized internal errors (`-32603`). This applies to static and
template resources. Do not return an empty contents list for a missing entry.


## Forms during resource reads

Read `company://welcome` in Inspector's **Resources** tab. The server asks for
`en` or `de`, then returns “Welcome” or “Willkommen”. Decline and cancel return
the default English greeting. The client must advertise form elicitation support.
This uses the example's existing elicitation signing key configuration.

Resource modules use the same pattern as tool forms:

```elixir
def read(_request) do
  {:ok, form} =
    Portico.Input.form("Choose a language",
      schema: %{
        type: "object",
        properties: %{language: %{type: "string", enum: ["en", "de"]}},
        required: ["language"]
      }
    )

  {:ok, form, "welcome:v1"}
end

def handle_input({:accept, %{"language" => language}}, "welcome:v1", _request) do
  text = if language == "de", do: "Willkommen", else: "Welcome"
  {:ok, content} = Portico.Resource.text(text)
  {:ok, content}
end

def handle_input(action, "welcome:v1", _request) when action in [:decline, :cancel] do
  {:ok, content} = Portico.Resource.text("Welcome")
  {:ok, content}
end
```

The input-required response ends the first HTTP request. The client sends the
answer in a new `resources/read` request for the same URI, echoing `requestState`.
Portico validates the signed continuation and form content before calling
`handle_input/3`. Missing or invalid content reissues the form. A handler may
return a single content item, a list, another form, or an error tuple.

In Elixir tests:

```elixir
mcp = %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}}}}
{:ok, _form, state} = read_resource mcp, "company://welcome"

{:ok, content} =
  read_resource mcp, "company://welcome",
    request_state: state,
    input_responses: %{"form" => %{"action" => "accept", "content" => %{"language" => "de"}}}

assert content.text == "Willkommen"
```

Continuations expire after five minutes and bind the server, resource module and
route, exact requested URI, form schema, and application state. Changing the key
invalidates saved replies. State is signed, not encrypted or single-use; keep
secrets out of it. Fresh assigns come from each request, not from the token.

For application identity checks, resources accept the same optional
`elicitation_verifier: &MyApp.Elicitation.verify/2` as tools. Portico always
checks the signed envelope first. Signing does not authenticate a user.

Missing form support returns `{:error, :form_not_supported}` in helpers and MCP
`-32021`. Invalid tokens return `{:error, :invalid_request_state}` and MCP
`-32602`. Resource streaming remains a future slice.


## URL elicitation during resource reads

Read `company://reviewed-report` to receive a browser approval link before the
resource returns the fictional report. This reuses the browser page and demo
identity checks from `approve_report`; it is not OAuth or account linking.

Launch Inspector with the same demo Authorization header:

```sh
npx @modelcontextprotocol/inspector \
  --server-url http://127.0.0.1:4000/mcp \
  --transport http \
  --protocol-era modern \
  --header "Authorization: Basic YWxpY2U6YWxpY2UtZGVtbw=="
```

Open **Resources** and read `company://reviewed-report`. Open its elicitation
URL, sign into the browser as `alice / alice-demo`, and click **Approve report**.
Return to Inspector and accept/retry the pending read. The result is
“Reviewed sample report: 3 orders, total 42 EUR.”

The MCP client must advertise URL elicitation support. The browser authenticates
separately; the MCP header is not automatically forwarded. Accepting before
browser approval reissues the URL. Decline or cancel returns status text without
the report. Without demo credentials, the example returns login instructions.

The resource uses the same callback shape as URL tools:

```elixir
{:ok, input} = Portico.Input.url("Review the report", url: review_url)
{:ok, input, approval_id}
```

`handle_input/3` receives `:accept`, `:decline` or `:cancel` and the verified
application state. On accept, check the browser workflow's completion and identity
before returning content. The example does that through `ReportApprovals.get/2`.

Test helpers use the same continuation options:

```elixir
mcp = %{mcp |
  assigns: %{demo_user: "alice"},
  client_capabilities: %{"elicitation" => %{"url" => %{}}}
}
{:ok, input, state} = read_resource mcp, "company://reviewed-report"
# Complete the application's browser workflow before retrying with accept.
{:ok, content} =
  read_resource mcp, "company://reviewed-report",
    request_state: state,
    input_responses: %{"url" => %{"action" => "accept"}}
```

URL replies omit `content`. The signed URL and state retain the same server,
resource route/URI binding and five-minute expiry as form reads. Missing URL
support returns `:url_not_supported` in helpers and MCP `-32021`.


### Rejecting a browser approval

Both `approve_report` and `company://reviewed-report` use the same approval page.
Choose **Reject report** to record a rejection, then return to the MCP client
and accept/retry the pending URL request. The application reads the browser's
decision: the tool returns an error result saying “Report approval rejected.”;
the resource returns that status text without the report.

The first browser decision is final for that approval request. Revisiting the
page shows the recorded decision; a stale form cannot change it. Start a new
tool call or resource read to create a new approval request. Browser rejection
is separate from declining or cancelling the URL prompt in the MCP client.


## Prompts

The `review_code` prompt prepares a user message for a code review. It does not
execute the supplied code or call an LLM. In Inspector, open **Prompts**, list
prompts, select **review_code**, enter `1 + 1` for **code**, and get the prompt.

Declare it in the server:

```elixir
prompt "review_code", PorticoExample.Prompts.ReviewCode
```

Its module owns the argument metadata and callback:

```elixir
defmodule PorticoExample.Prompts.ReviewCode do
  use Portico.Prompt,
    description: "Prepare a code review request.",
    arguments: [code: [description: "Code to review", required: true]]

  def get(%{"code" => code}, _request) do
    {:ok, prompt} = Portico.Prompt.text("Review this code for bugs:\n\n#{code}")
    {:ok, prompt}
  end
end
```

Arguments are named strings, not JSON Schema objects. Declare them as a keyword
list with optional `description:` and `required:` (default `false`). Portico
rejects missing required arguments, undeclared names and non-string values before
calling `get/2`. Empty strings are valid; optional absent values stay absent.
Omitting `arguments` in a protocol request supplies an empty map.

The fresh request exposes `server`, `prompt_name`, `arguments`, protocol metadata
and application assigns. Authentication and authorization remain application-owned;
the static catalog is not filtered by identity.

```elixir
{:ok, prompt} = get_prompt mcp, "review_code", %{"code" => "1 + 1"}
assert prompt.messages == [
  %{role: "user", content: %{type: "text", text: "Review this code for bugs:\n\n1 + 1"}}
]
```

The helper accepts a server module or test context and optional `assigns:`.
Unknown names return `{:error, :unknown_prompt}`; argument failures return
`{:error, :invalid_params}`. Both map to MCP `-32602`. Callback errors stay
visible as tuples in helpers, while HTTP sanitizes them as `-32603`. Invalid
constructor text returns `{:error, :invalid_text}`; malformed prompt structs
return `{:error, :invalid_prompt}`. Invalid declarations fail at compilation.

`prompts/list` is sorted by name and uses private caching with zero TTL. Cursors
are rejected in this slice. `Prompt.text/1` creates one user-role text message.
Completion, multiple/rich messages, prompt elicitation and subscriptions remain
follow-ups. Include `import_deps: [:portico]` in your formatter configuration to
keep `prompt` and `get_prompt` calls without parentheses.
