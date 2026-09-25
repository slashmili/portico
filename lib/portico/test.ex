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

  Calls supply valid default metadata and use the shared protocol validators,
  tool execution, and result encoder. Customize `protocol_version`, `client_info`,
  or `client_capabilities` on the context to test different client declarations.
  Each synchronous helper call uses request ID `1`; no session state is retained.

  Tool arguments use the same compiled schema validation as HTTP calls. Schema
  failures return an error Result without invoking the callback; valid arguments
  pass through unchanged. Authorization hooks and recursive JSON-value checks
  remain separate work. A passing helper test does not establish HTTP conformance.
  """

  alias Portico.Result
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

  Tool names must be strings and arguments must be string-keyed plain maps. Raises
  `ArgumentError` for an unknown tool, invalid options, or an invalid callback
  return shape or content. Metadata and version failures also raise
  `ArgumentError`. Exceptions raised by the tool propagate to the test, while
  the protocol entry point converts them to a generic internal error.

  Schema-invalid argument objects return `Portico.Result.error/1` without
  running the callback. Malformed argument containers remain request errors.

  Handles immediate results and `{:noreply, data, :stream}` outcomes, returning
  the final result including its `is_error` flag. Streaming uses the same worker
  and progress validation as HTTP. `timeout:` bounds streaming work (default
  5,000 milliseconds); expiry stops the task and raises.

  Supply `on_progress: fn update -> ... end` to collect progress. The helper
  supplies a progress token and calls this function in the test process, with
  an atom-keyed map containing `:progress` and optional `:total`/`:message`.
  Exceptions in the callback stop the worker and propagate to the test.

      result = call_tool mcp, "count", %{"to" => 3},
        on_progress: fn update -> send(self(), {:progress, update}) end
      assert_text result, "3"
      assert_received {:progress, %{progress: 1, total: 3}}

  """
  @spec call_tool(module() | Context.t(), String.t(), map(), keyword()) :: Result.t()
  def call_tool(target, name, arguments, options \\ [])

  def call_tool(%Context{server: server, assigns: defaults} = context, name, arguments, options) do
    options = Keyword.validate!(options, assigns: %{}, on_progress: nil, timeout: 5_000)

    unless is_integer(options[:timeout]) and options[:timeout] > 0,
      do: raise(ArgumentError, "expected a positive :timeout in milliseconds")

    unless is_nil(options[:on_progress]) or is_function(options[:on_progress], 1),
      do: raise(ArgumentError, "expected :on_progress to be a function of one argument")

    assigns = Keyword.fetch!(options, :assigns)
    validate_assigns!(defaults)
    validate_assigns!(assigns)

    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => context.protocol_version,
      "io.modelcontextprotocol/clientCapabilities" => context.client_capabilities
    }

    metadata =
      if is_nil(context.client_info),
        do: metadata,
        else: Map.put(metadata, "io.modelcontextprotocol/clientInfo", context.client_info)

    metadata =
      if options[:on_progress],
        do: Map.put(metadata, "progressToken", System.unique_integer([:positive])),
        else: metadata

    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments, "_meta" => metadata}
    }

    case Dispatcher.call_tool_request(server, message, Map.merge(defaults, assigns)) do
      {:ok, result} -> result
      {:stream, execution} -> collect_stream(execution, options)
      {:error, :unknown_tool} -> raise ArgumentError, "unknown tool #{inspect(name)}"
      {:error, reason} -> raise ArgumentError, "invalid tool request: #{inspect(reason)}"
    end
  end

  def call_tool(server, name, arguments, options) when is_atom(server) do
    call_tool(%Context{server: server}, name, arguments, options)
  end

  defp collect_stream(execution, options) do
    emit = fn
      {:progress, progress}, acc ->
        options[:on_progress].(progress)
        {:ok, acc}

      :heartbeat, acc ->
        {:ok, acc}
    end

    case Portico.Stream.Runner.run(execution, nil, emit, options[:timeout]) do
      {:ok, result, _} -> result
      {:failed, kind, reason, stack, _} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp validate_assigns!(assigns) do
    unless is_map(assigns) and not is_struct(assigns) and
             Enum.all?(Map.keys(assigns), &is_atom/1) do
      raise ArgumentError, "expected :assigns to be a plain map with atom keys"
    end
  end
end
