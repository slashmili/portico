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

Current support: discovery, tool listing, and completed text tool calls through
`Portico.Plug`, including explicit tool errors with `Portico.Result.error/1`.
Schema declarations are checked at compile time against Draft 2020-12, and
arguments are validated before callbacks run. Streaming and elicitation remain
in progress.

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
