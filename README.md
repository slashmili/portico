# Portico

An Elixir MCP server library with module-based tool routing, request context,
Plug integration, and ExUnit helpers. Work in progress, targeting MCP 2026-07-28.

```elixir
defmodule MyApp.MCP do
  use Portico.Server, name: "my-app", version: "0.1.0"

  tool "add", MyApp.Tools.Add
end
```

Each tool module owns its raw JSON Schema and `call/2` callback. The host
application owns the HTTP listener; Portico does not start one automatically.

See the [runnable example](example/README.md) for a complete tool, a local Bandit
server, and real HTTP tests using the official Python MCP client.

Current support: discovery, tool listing, and text or structured tool results through
`Portico.Plug`, including explicit tool errors with `Portico.Result.error/1`.
Schema declarations are checked at compile time against Draft 2020-12, and
arguments are validated before callbacks run. Tools can choose JSON replies or
request-scoped progress streams with `{:noreply, data, :stream}` and
`handle_stream/2`. Form elicitation supports signed continuation state, validated
replies, and single or multiple choices.

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
need recovery; the explicit match above asserts success. Output-schema declarations
are not supported yet. Try the example's `summarize` tool for structured results.

Only MCP **2026-07-28** is implemented. Resources, prompts, subscriptions, stdio,
legacy protocol versions, and URL elicitation are outside the current scope.
Custom `x-mcp-header` annotations are not supported; omit them from tool schemas.
The host application owns authentication, authorization, and rate limiting.
Passing user assigns through Plug does not provide MCP OAuth support.

Run library checks with:

```sh
mix deps.get
mix test --warnings-as-errors --cover
mix format --check-formatted
```

GitHub Actions runs these checks on pushes and pull requests, plus the example's
Elixir and Python MCP E2E suites. Library coverage must be at least **91%**, keeping
it above the 90% target. Local asdf installs and CI share the Elixir/Erlang versions in
[.tool-versions](.tool-versions). CI uses Python 3.14. See [the workflow](.github/workflows/ci.yml).
