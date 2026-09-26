# Portico

An Elixir MCP server library with module-based tool routing, request context,
Plug integration, and ExUnit helpers. Work in progress, targeting MCP 2026-07-28.

## Quickstart

In your application's `mix.exs`, add the Git dependency while Portico is in
development:

```elixir
{:portico, git: "https://github.com/slashmili/portico.git"}
```

Run `mix deps.get`. Define a tool with its raw JSON Schema and callback:

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
`call_tool`, `resource`, `resource_template`, `read_resource`, and `assert_text` calls without parentheses.

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

Only MCP **2026-07-28** is implemented. Prompts, subscriptions, stdio,
and legacy protocol versions are outside the current scope.
Custom `x-mcp-header` annotations are rejected at compilation; omit them from tool input schemas.
The host application owns authentication, authorization, and rate limiting.
Passing user assigns through Plug does not provide MCP OAuth support.

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
