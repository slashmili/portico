# Portico

An Elixir MCP server library with module-based tool routing, request context,
Plug integration, and ExUnit helpers. Work in progress, targeting MCP 2026-07-28.

## Quickstart

In your application's `mix.exs`, add the Git dependency while Portico is in
development:

```elixir
{:portico, git: "https://github.com/slashmili/portico.git"}
```

Run `mix deps.get`. Define a tool with its raw JSON Schema and callback.
Input schemas must explicitly declare `type: "object"` at the root. For a tool
with no arguments, use `%{type: "object", additionalProperties: false}`.
Missing or non-object roots fail compilation; output schemas may describe any
JSON type.


```elixir
defmodule MyApp.Tools.Add do
  use Portico.Tool,
    description: "Add two integers.",
    input_schema: %{
      type: "object",
      properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
      required: ["a", "b"],
      additionalProperties: false
    }

  @impl true
  def call(%{"a" => a, "b" => b}, _request) do
    # JSON Schema also accepts integral floats, such as 2.0, as integers.
    {:ok, result} = Portico.Result.text(Integer.to_string(trunc(a) + trunc(b)))
    {:ok, result}
  end
end

defmodule MyApp.MCP do
  use Portico.Server, name: "my-app", version: "0.1.0"

  tool "add", MyApp.Tools.Add
end
```

In a Phoenix router, mount Portico outside the browser/CSRF pipeline:

```elixir
forward "/mcp", Portico.Plug,
  server: MyApp.MCP,
  allowed_origins: ["https://my-app.example"]
```

For a `Plug.Router`, use its forwarding syntax instead:

```elixir
forward "/mcp", to: Portico.Plug, init_opts: [
  server: MyApp.MCP,
  allowed_origins: ["https://my-app.example"]
]
```

The host application owns the HTTP listener; Portico does not start one.
Requests without an Origin header are accepted. If Origin is present, it must
match the explicit allowlist. This check does not configure browser CORS.
Connect an MCP **2026-07-28** client to your application's `/mcp` endpoint.

Test the routed tool without an HTTP listener:

```elixir
defmodule MyApp.MCPTest do
  use Portico.Test, server: MyApp.MCP, async: true

  test "adds two integers", %{mcp: mcp} do
    {:ok, result} = call_tool mcp, "add", %{"a" => 2, "b" => 3}
    assert_text result, "5"
  end
end
```

`Portico.Test` supplies a fresh context for each test. Add
`import_deps: [:portico]` to your `.formatter.exs` options to keep `tool`,
`call_tool`, `resource`, `resource_template`, `read_resource`, `prompt`, `get_prompt`, `complete`, and `assert_text` calls without parentheses.

See the [runnable example](https://github.com/slashmili/portico/tree/HEAD/example)
for a standalone Bandit server, forms, streaming, and real HTTP tests using the
official Python MCP client.

## Current scope

Current support: discovery, tool listing, and text or structured tool results through
`Portico.Plug`, including explicit tool errors with `Portico.Result.error/1`.
Schema declarations are checked at compile time against Draft 2020-12, and
arguments are validated before callbacks run. Tools can choose JSON replies or
request-scoped progress streams with `{:noreply, data, :stream}` and
`handle_stream/2`. Form elicitation supports signed continuation state, validated
replies, and single or multiple choices. URL elicitation supports browser workflows with
application-owned completion and identity checks.

Return structured JSON using the same callback contract:

```elixir
def call(%{"a" => a, "b" => b}, _request) do
  {:ok, result} = Portico.Result.structured(%{sum: a + b})
  {:ok, result}
end
```

`Result.structured/1` accepts any JSON value, normalizes atom map keys to strings,
and includes a JSON text fallback alongside `structuredContent`. Invalid values
return `{:error, :invalid_structured_content}`. Use `case` if construction errors
need recovery; the explicit match above asserts success. Tools can declare an
optional `output_schema:` alongside `input_schema:`:

```elixir
output_schema: %{
  type: "object",
  properties: %{sum: %{type: "integer"}},
  required: ["sum"],
  additionalProperties: false
}
```

Portico checks the declaration at compilation, advertises it in `tools/list`, and
validates successful structured results, including streams and form continuations.
Missing or mismatched output returns `{:error, :invalid_output}` in test helpers
and a sanitized internal error over HTTP. Expected `Result.error/1` failures do
not need to match the output schema. Try the example's `summarize` tool.

Text and binary resources support static URIs and templates with whole path variables, with
a `read_resource` test helper. See the example handbook and handbook-section resources.

Resource reads can return one item or a list with per-item URI and MIME metadata,
or request form/URL elicitation and resume through `handle_input/3`. See
`company://welcome` and `company://reviewed-report` in the example.

Prompts support listing and retrieval with validated string arguments. Define a
`Portico.Prompt` module, route it with `prompt "review_code", MyApp.Prompts.ReviewCode`,
and test it with `get_prompt mcp, "review_code", %{"code" => "1 + 1"}`.
The first slice returns one user-role text message; it does not call an LLM.

Optional `complete/3` callbacks suggest prompt arguments and resource-template
variables. Use `Portico.Test.complete/5` to test them.

Only MCP **2026-07-28** is implemented. Catalog-change subscriptions, stdio,
and legacy protocol versions are outside the current scope.
Custom `x-mcp-header` annotations are rejected at compilation; omit them from tool input schemas.
The host application owns token verification, operation authorization, and rate limiting.
Optional `Portico.OAuth` provides the OAuth resource-server integration described below.

## Optional OAuth integration

Protect an MCP endpoint with `Portico.OAuth` before `Portico.Plug`:

```elixir
plug Portico.OAuth,
  resource: "https://example.com/mcp",
  authorization_servers: ["https://auth.example.com"],
  scopes: ["mcp:access"],
  verify_token: &MyApp.Auth.verify_mcp_token/2

plug Portico.Plug, server: MyApp.MCP, assigns: [:current_user]
```

Scope this pipeline to the protected MCP endpoint. Also mount a **public** GET
route at `/.well-known/oauth-protected-resource/mcp` that calls
`Portico.OAuth.metadata(conn, options)`, using the same options returned by
`Portico.OAuth.init/1`. Discovery must remain outside the protected pipeline.
The metadata URL is derived from the configured resource URL, including its path.

Your verifier receives `token` and `%{resource: resource, scopes: scopes}`. Return
`{:ok, %{current_user: user}}`, `{:error, :invalid_token}` (401),
`{:error, :insufficient_scope}` (403), or `{:error, :temporarily_unavailable}` (503).
It must validate authenticity, trusted issuer, expiry, resource audience and scopes
using your provider's JWT validation or trusted token introspection/store.
Portico invokes it on every authenticated request and forwards successful assigns.
Invalid callback returns or callback crashes produce a generic 500 without exposing
the token or error details. Invalid configuration fails at Plug initialization.

This implements the resource-server boundary of
[MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization).
Login, consent, client registration, token issuance and refresh belong to an
authorization provider. JWT verification and introspection adapters are not bundled.
The host also configures CORS where needed and each callback authorizes its operation.
See [the example](example/README.md#optional-protected-endpoint) for runnable routing,
a demo verifier, curl commands and Inspector instructions. The demo uses fixed tokens;
it does not provide a browser login flow.

## Development

Run library checks with:

```sh
mix deps.get
mix test --warnings-as-errors --cover
mix format --check-formatted
```

Generate the API documentation locally with `mix docs --warnings-as-errors`, then
open `doc/index.html`. ExDoc is a development-only dependency. The
[changelog](https://github.com/slashmili/portico/blob/HEAD/CHANGELOG.md) tracks
unreleased changes.

GitHub Actions runs these checks on pushes and pull requests, plus the example's
Elixir and Python MCP E2E suites. Library coverage must be at least **91%**, keeping
it above the 90% target. Local asdf installs and CI share the Elixir/Erlang versions in
[.tool-versions](https://github.com/slashmili/portico/blob/HEAD/.tool-versions). CI uses Python 3.14. See [the workflow](https://github.com/slashmili/portico/blob/HEAD/.github/workflows/ci.yml).

## License

MIT — see [LICENSE](https://github.com/slashmili/portico/blob/HEAD/LICENSE).
Copyright (c) 2026 Portico contributors.

## Resource subscriptions

Implement these callbacks in the server module to support `subscriptions/listen`:

```elixir
@impl true
def handle_subscribe(filter, request) do
  # Authentication and topic authorization belong to your application.
  topic = "reports:#{request.assigns.current_user.id}"
  accepted = Enum.filter(filter.resource_subscriptions, &(&1 == "company://report"))
  if accepted != [], do: Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
  {:ok, %{resource_subscriptions: accepted}, %{}}
end

@impl true
def handle_info({:report_changed, uri}, state) do
  :ok = Portico.Subscription.send({:resource_updated, uri})
  {:noreply, state}
end

def handle_info(_message, state), do: {:noreply, state}
```

`Portico.Subscription.send/1` runs inside `handle_info/2` and returns `:ok` or an
error tuple. It uses the current callback process's subscription; spawned tasks
cannot send directly. Valid updates outside the accepted URI filter are ignored.

Each HTTP subscription has its own task and application state. The callbacks run
in that task; the server module itself is not a GenServer. Portico acknowledges
with the accepted filter, sends updates only for accepted URIs, and stops the
task on disconnect. Your event source must remove registrations when subscribers
exit, as Phoenix.PubSub and Registry do. No new dependency is required by Portico.

The callback receives `%{resource_subscriptions: [uri]}` and fresh request assigns.
Use them to authorize access before subscribing. Return
`{:ok, %{resource_subscriptions: accepted_uris}, state}` with a subset of the
requested URIs; return an empty list when none are supported. Portico rejects
unrequested URIs or malformed filters and removes duplicates. Server-wide
subscription support does not mean every resource accepts subscriptions.
A notification contains the URI;
the client reads the resource again to obtain content. Return `{:stop, :normal, state}`
for a graceful final response, or `{:error, reason}` for a sanitized protocol error.
The default subscription lifetime is unlimited; configure `subscription_timeout:`
on `Portico.Plug` in milliseconds to bound it. Tool `stream_timeout` is independent.
Heartbeats detect disconnects even when application callbacks are blocked.

This slice supports resource updates only. Catalog-change flags are omitted from
the acknowledgement. There is no retained history or replay; reconnect and reread.
Applications own identity checks, event sources, subscriber limits and network
write timeouts. See the node-local Registry demonstration in `example/`.

## Text sampling

A tool can ask the client's model for a text generation:

```elixir
def call(%{"text" => text}, _request) do
  {:ok, input} = Portico.Input.sample("Summarize this:\n#{text}", max_tokens: 200)
  {:ok, input, "summarize:v1"}
end

def handle_input({:sample, %{text: text}}, "summarize:v1", _request) do
  {:ok, result} = Portico.Result.text(text)
  {:ok, result}
end
```

The client must advertise `sampling`. Portico returns `sampling/createMessage`
inside `inputRequests`; the client runs its model and retries the tool call with
`inputResponses`. The answer includes `text`, `model` and optional `stop_reason`.
No server process waits between requests, and a declined request may never retry.

This initial slice supports tools with one user text prompt and one text answer.
Constructors return error tuples. Missing capability returns `-32021`; malformed
answers return `-32602`. Missing answers reissue the input. The client controls
model selection and must respect the positive `max_tokens` limit.

Continuations use the existing per-server `elicitation_key` and five-minute expiry.
Tokens bind the sampling request and state to the server, tool and arguments.
They are signed, not encrypted or single-use. Elicitation-specific custom verifiers
remain limited to forms/URLs; check fresh request assigns in the sampling handler
for application authorization. Sampling is deprecated but retained in MCP
2026-07-28; Portico does not add support for older protocol versions.
See the separate `summarize_text` example and its Python sampling callback.

## Tool behavior hints

Add optional boolean hints to the tool declaration:

```elixir
use Portico.Tool,
  input_schema: %{type: "object", additionalProperties: false},
  annotations: [read_only: true, open_world: false]
```

| Elixir key | MCP annotation | Meaning when true |
| --- | --- | --- |
| `read_only` | `readOnlyHint` | Does not modify its environment |
| `destructive` | `destructiveHint` | May perform destructive updates |
| `idempotent` | `idempotentHint` | Repeating identical arguments has no additional effect |
| `open_world` | `openWorldHint` | May interact with external entities |

Destructive/idempotent hints apply to tools that modify their environment.
These hints describe behavior; they do not enforce permissions or change callback
execution. Clients must treat annotations from untrusted servers as untrusted.
Only supplied hints appear in `tools/list`; `annotations: []` omits the field.
MCP defaults for omitted hints are respectively false, true, false and true.
Unknown keys, duplicate keys and non-boolean values fail compilation.
`Portico.Server.tools/1` exposes supplied hints in an atom-keyed annotations map.
