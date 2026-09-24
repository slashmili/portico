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
Schema declarations are checked at compile time against Draft 2020-12. Argument
validation, streaming, and elicitation remain in progress.

Run library checks with:

```sh
mix deps.get
mix test --warnings-as-errors --cover
mix format --check-formatted
```
