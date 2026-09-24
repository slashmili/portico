defmodule Portico.Test do
  @moduledoc """
  Helpers for testing declared tools without opening an HTTP listener.

      defmodule MyApp.MCPTest do
        use Portico.Test, server: MyApp.MCP, async: true

        test "adds numbers", %{mcp: mcp} do
          result = call_tool mcp, "add", %{"a" => 2, "b" => 3}
          assert_text result, "5"
        end
      end

  `use Portico.Test` sets up `ExUnit.Case`, imports the helpers, and supplies a
  fresh `:mcp` context for each test. No user-written `setup` block is required.
  Supported options are the required `:server` and optional `:async` (defaults
  to `false`).

  If several tests need shared application assigns, optionally define one setup
  block for the test module. It runs with a fresh context before each test:

      setup %{mcp: mcp} do
        %{mcp: %{mcp | assigns: %{current_user: build_user()}}}
      end

  Override assigns for a single invocation:

      result = call_tool mcp, "add", %{"a" => 2, "b" => 3},
        assigns: %{current_user: user}

  Alternatively, use `ExUnit.Case` and `import Portico.Test` to call a server
  module directly:

      result = call_tool MyApp.MCP, "add", %{"a" => 2, "b" => 3}

  Add `import_deps: [:portico]` to your application's `.formatter.exs` to keep
  these calls without parentheses when running `mix format`.

  Calls use Portico's shared dispatcher. Currently it checks tool lookup and
  the callback return shape; schema validation, protocol metadata validation,
  authorization hooks, and HTTP handling are not implemented. Arguments are
  passed through unchanged. A passing helper test does not establish MCP or
  HTTP conformance.
  """

  alias Portico.{Request, Result}
  alias Portico.Protocol.Dispatcher
  alias Portico.Test.Context

  @doc false
  defmacro __using__(options) do
    options = Keyword.validate!(options, [:server, :async])
    server = Keyword.fetch!(options, :server)
    case_options = Keyword.take(options, [:async])

    quote do
      use ExUnit.Case, unquote(case_options)
      import Portico.Test

      setup do
        %{mcp: %Portico.Test.Context{server: unquote(server)}}
      end
    end
  end

  @doc """
  Asserts that a result contains a text item exactly equal to `expected`.

  Text items are checked individually, without joining them or matching
  substrings. Raises `ExUnit.AssertionError` on failure and returns the original
  result on success. Both arguments are evaluated once.

      assert_text result, "5"
  """
  defmacro assert_text(result, expected) do
    quote do
      require ExUnit.Assertions

      result = unquote(result)
      expected = unquote(expected)
      ExUnit.Assertions.assert(%Portico.Result{content: content} = result)
      ExUnit.Assertions.assert(is_list(content))
      ExUnit.Assertions.assert(is_binary(expected))
      texts = for %{type: "text", text: text} <- content, do: text
      ExUnit.Assertions.assert(expected in texts)
      result
    end
  end

  @doc """
  Invokes a named tool and returns its completed result.

  Accepts a `Portico.Test.Context` or a server module. Each invocation creates a
  fresh `Portico.Request`. Supply application context
  with `assigns: %{current_user: user}`; assigns must be a plain map with atom
  keys. The helper does not authenticate this context.

  Context assigns are defaults. Per-call assigns override matching keys without
  modifying the context or affecting subsequent calls. Direct module calls
  start with empty assigns.

  Tool names must be strings and arguments must be plain maps. Raises
  `ArgumentError` for an unknown tool, invalid options, or an invalid callback
  return shape. Exceptions raised by the tool propagate to the test.

  Only `{:reply, %Portico.Result{}, %Portico.Request{}}` outcomes are supported.
  The updated request is retained by the dispatcher; this helper returns only
  the result.
  """
  @spec call_tool(module() | Context.t(), String.t(), map(), keyword()) :: Result.t()
  def call_tool(target, name, arguments, options \\ [])

  def call_tool(%Context{server: server, assigns: defaults}, name, arguments, options) do
    options = Keyword.validate!(options, assigns: %{})
    assigns = Keyword.fetch!(options, :assigns)
    validate_assigns!(defaults)
    validate_assigns!(assigns)

    request = %Request{assigns: Map.merge(defaults, assigns)}

    case Dispatcher.call_tool(server, name, arguments, request) do
      {:reply, result, _request} -> result
      {:error, :unknown_tool} -> raise ArgumentError, "unknown tool #{inspect(name)}"
    end
  end

  def call_tool(server, name, arguments, options) when is_atom(server) do
    call_tool(%Context{server: server}, name, arguments, options)
  end

  defp validate_assigns!(assigns) do
    unless is_map(assigns) and not is_struct(assigns) and
             Enum.all?(Map.keys(assigns), &is_atom/1) do
      raise ArgumentError, "expected :assigns to be a plain map with atom keys"
    end
  end
end
