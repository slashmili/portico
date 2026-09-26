defmodule Portico do
  @moduledoc """
  Build MCP servers with module-based tools and Plug integration.

  Define tool schemas and callbacks with `Portico.Tool`, then register them with
  `Portico.Server`. Mount `Portico.Plug` in the host application's router; the
  application owns the HTTP listener, authentication, and authorization.

  Callbacks receive a `Portico.Request` and return `{:ok, result}` using the
  tuple-returning `Portico.Result` constructors. Tools can also request form
  input with `Portico.Input` or stream progress with `Portico.Stream`.
  Define static text resources with `Portico.Resource` and register them with
  `Portico.Server.resource/2`. `Portico.Test` exercises tools and resources without
  an HTTP listener.

  Portico targets MCP 2026-07-28. See the README for a complete quickstart and
  the supported protocol scope.
  """
end
