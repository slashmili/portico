defmodule Portico.Test do
  @moduledoc """
  Helpers for testing declared tools, resources and prompts without an HTTP listener.

      defmodule MyApp.MCPTest do
        use Portico.Test, server: MyApp.MCP, async: true

        test "adds numbers", %{mcp: mcp} do
          {:ok, result} = call_tool mcp, "add", %{"a" => 2, "b" => 3}
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

      {:ok, result} = call_tool mcp, "add", %{"a" => 2, "b" => 3},
        assigns: %{current_user: user}

  Alternatively, use `ExUnit.Case` and `import Portico.Test` to call a server
  module directly:

      {:ok, result} = call_tool MyApp.MCP, "add", %{"a" => 2, "b" => 3}

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
  Invokes a named tool and returns `{:ok, result}` or `{:error, reason}`.

  Accepts a `Portico.Test.Context` or a server module. Each invocation creates a
  fresh `Portico.Request`. Supply application context
  with `assigns: %{current_user: user}`; assigns must be a plain map with atom
  keys. The helper does not authenticate this context.

  Context assigns are defaults. Per-call assigns override matching keys without
  modifying the context or affecting subsequent calls. Direct module calls
  start with empty assigns.

  Tool names must be strings and arguments must be string-keyed plain maps.
  Portico validation failures return `{:error, reason}`: for example
  `:unknown_tool`, `:invalid_params`, `:invalid_callback_return`, `:invalid_result`,
  or `:missing_stream_callback`. Invalid helper configuration also returns a
  reason such as `:invalid_options`, `:invalid_assigns`, or `:invalid_server`.
  Callback `{:error, reason}` returns are preserved, including arbitrary reason
  terms, for both immediate and streaming calls.
  Application callback exceptions still propagate to the test, while HTTP
  converts them to a generic internal error. Failed assertions still raise.

  Schema-invalid argument objects return `{:ok, %Portico.Result{is_error: true}}`
  without running the callback. This is a completed tool result, distinct from
  a library failure. Malformed argument containers return `{:error, :invalid_params}`.

  Handles immediate results and `{:noreply, data, :stream}` outcomes through the
  same worker and progress validation as HTTP. Both return `{:ok, result}` on
  completion. `timeout:` bounds streaming work (default 5,000 milliseconds);
  expiry stops the task and returns `{:error, :timeout}`.

  URL calls return `{:ok, %Portico.Input{mode: :url}, signed_state}`. Declare
  `%{"elicitation" => %{"url" => %{}}}` in client capabilities and retry with
  `request_state: signed_state, input_responses: %{"url" => %{"action" => "accept"}}`.
  URL replies must omit `content`. Missing URL support returns
  `{:error, :url_not_supported}`. A retry may return another input if the browser
  workflow is still pending; application code owns checking completion.

  Form calls, including forms returned after streamed progress, return
  `{:ok, %Portico.Input{}, wire_state}`. To submit a reply,
  call the same tool and arguments with `request_state: wire_state` and
  `input_responses: %{"form" => %{"action" => "accept", "content" => %{"name" => "Ada"}}}`.
  Declare `%{"elicitation" => %{"form" => %{}}}` in the context's client
  capabilities. Missing form support returns `{:error, :form_not_supported}`
  for initial calls, retries, and streaming callbacks. The helper uses the same verification and schema checks as HTTP.

  Supply `on_progress: fn update -> ... end` to collect progress. The helper
  supplies a progress token and calls this function in the test process, with
  an atom-keyed map containing `:progress` and optional `:total`/`:message`.
  Exceptions in the callback stop the worker and propagate to the test.

      {:ok, result} = call_tool mcp, "count", %{"to" => 3},
        on_progress: fn update -> send(self(), {:progress, update}) end
      assert_text result, "3"
      assert_received {:progress, %{progress: 1, total: 3}}

  """
  @spec call_tool(module() | Context.t(), String.t(), map(), keyword()) ::
          {:ok, Result.t()} | {:ok, Portico.Input.t(), String.t()} | {:error, term()}
  def call_tool(target, name, arguments, options \\ [])

  def call_tool(%Context{server: server, assigns: defaults} = context, name, arguments, options) do
    with {:ok, options} <- validate_options(options),
         :ok <- validate_server(server),
         :ok <- validate_assigns(defaults),
         :ok <- validate_assigns(options[:assigns]) do
      invoke(context, name, arguments, options)
    end
  end

  def call_tool(server, name, arguments, options) when is_atom(server) do
    call_tool(%Context{server: server}, name, arguments, options)
  end

  def call_tool(_target, _name, _arguments, _options), do: {:error, :invalid_target}

  @doc """
  Completes a prompt argument or resource-template variable through protocol validation.

      {:ok, result} = complete mcp, {:prompt, "explain_code"}, "language", "el"
      assert result.values == ["elixir"]

  Use `{:resource, "company://policies/{name}"}` for templates. Options are
  `arguments:` (previously resolved string values) and `assigns:`. Returns
  `{:ok, %{values: values, total: count, has_more: boolean}}` or `{:error, reason}`.
  Application errors remain tuples and exceptions surface in tests.
  """
  @spec complete(
          module() | Context.t(),
          {:prompt | :resource, String.t()},
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def complete(target, ref, argument, prefix, options \\ [])

  def complete(%Context{} = context, ref, argument, prefix, options) do
    with true <-
           Keyword.keyword?(options) and
             Enum.all?(Keyword.keys(options), &(&1 in [:assigns, :arguments])),
         :ok <- validate_server(context.server),
         :ok <- validate_assigns(context.assigns),
         assigns = Keyword.get(options, :assigns, %{}),
         :ok <- validate_assigns(assigns),
         {:ok, reference} <- completion_reference(ref) do
      metadata = %{
        "io.modelcontextprotocol/protocolVersion" => context.protocol_version,
        "io.modelcontextprotocol/clientCapabilities" => context.client_capabilities
      }

      metadata =
        if is_nil(context.client_info),
          do: metadata,
          else: Map.put(metadata, "io.modelcontextprotocol/clientInfo", context.client_info)

      message = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "completion/complete",
        "params" => %{
          "ref" => reference,
          "argument" => %{"name" => argument, "value" => prefix},
          "context" => %{"arguments" => Keyword.get(options, :arguments, %{})},
          "_meta" => metadata
        }
      }

      Dispatcher.complete_request(context.server, message, Map.merge(context.assigns, assigns))
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  end

  def complete(server, ref, argument, prefix, options) when is_atom(server),
    do: complete(%Context{server: server}, ref, argument, prefix, options)

  def complete(_, _, _, _, _), do: {:error, :invalid_target}

  defp completion_reference({:prompt, name}), do: {:ok, %{"type" => "ref/prompt", "name" => name}}

  defp completion_reference({:resource, uri}),
    do: {:ok, %{"type" => "ref/resource", "uri" => uri}}

  defp completion_reference(_), do: {:error, :invalid_params}

  @doc """
  Gets a declared prompt through protocol validation without HTTP.

      {:ok, prompt} = get_prompt mcp, "review_code", %{"code" => "1 + 1"}

  Accepts a server module or context, string-keyed string arguments and optional
  `assigns:` overrides. Returns `{:ok, %Portico.Prompt{}}` or `{:error, reason}`.
  Missing required/unknown arguments return `:invalid_params`; unknown prompts
  return `:unknown_prompt`. Application callback errors remain tuples and
  callback exceptions surface in tests. HTTP sanitizes callback failures.
  """
  @spec get_prompt(module() | Context.t(), String.t(), map(), keyword()) ::
          {:ok, Portico.Prompt.t()} | {:error, term()}
  def get_prompt(target, name, arguments, options \\ [])

  def get_prompt(%Context{} = context, name, arguments, options) do
    with true <- Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 == :assigns)),
         :ok <- validate_server(context.server),
         :ok <- validate_assigns(context.assigns),
         assigns = Keyword.get(options, :assigns, %{}),
         :ok <- validate_assigns(assigns) do
      metadata = %{
        "io.modelcontextprotocol/protocolVersion" => context.protocol_version,
        "io.modelcontextprotocol/clientCapabilities" => context.client_capabilities
      }

      metadata =
        if is_nil(context.client_info),
          do: metadata,
          else: Map.put(metadata, "io.modelcontextprotocol/clientInfo", context.client_info)

      message = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{"name" => name, "arguments" => arguments, "_meta" => metadata}
      }

      Dispatcher.get_prompt_request(context.server, message, Map.merge(context.assigns, assigns))
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  end

  def get_prompt(server, name, arguments, options) when is_atom(server),
    do: get_prompt(%Context{server: server}, name, arguments, options)

  def get_prompt(_, _, _, _), do: {:error, :invalid_target}

  @doc """
  Reads a static or template resource through protocol validation without HTTP.

      {:ok, content} = read_resource mcp, "company://handbook"
      assert content.text == "Welcome to the company."

  Accepts a server module or test context and an optional `assigns:` override.
  Returns `{:ok, %Portico.Resource{}}` with the requested URI and declared MIME type,
  while a list callback returns `{:ok, [content]}` preserving each item's URI/MIME type.
  Failures return `{:error, reason}`. Callback exceptions remain visible in tests.

  Forms return `{:ok, %Portico.Input{}, signed_state}`. Set
  `%{"elicitation" => %{"form" => %{}}}` in context client capabilities and retry
  the same URI with `request_state:` and `input_responses:`, as for tool forms.
  URL inputs use the same tuple with `mode: :url`. Declare the client's
  `elicitation.url` capability, then retry with
  `input_responses: %{"url" => %{"action" => "accept"}}` (no content).
  Resource streaming remains unsupported.
  """
  @spec read_resource(module() | Context.t(), String.t(), keyword()) ::
          {:ok, Portico.Resource.t() | [Portico.Resource.t()]}
          | {:ok, Portico.Input.t(), String.t()}
          | {:error, term()}
  def read_resource(target, uri, options \\ [])

  def read_resource(%Context{} = context, uri, options) do
    with true <-
           Keyword.keyword?(options) and
             Enum.all?(
               Keyword.keys(options),
               &(&1 in [:assigns, :request_state, :input_responses])
             ),
         :ok <- validate_server(context.server),
         :ok <- validate_assigns(context.assigns),
         assigns = Keyword.get(options, :assigns, %{}),
         :ok <- validate_assigns(assigns) do
      metadata = %{
        "io.modelcontextprotocol/protocolVersion" => context.protocol_version,
        "io.modelcontextprotocol/clientCapabilities" => context.client_capabilities
      }

      metadata =
        if is_nil(context.client_info),
          do: metadata,
          else: Map.put(metadata, "io.modelcontextprotocol/clientInfo", context.client_info)

      params =
        Enum.reduce(
          [request_state: "requestState", input_responses: "inputResponses"],
          %{"uri" => uri, "_meta" => metadata},
          fn {option, key}, params ->
            if Keyword.has_key?(options, option),
              do: Map.put(params, key, options[option]),
              else: params
          end
        )

      message = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "resources/read",
        "params" => params
      }

      Dispatcher.read_resource_request(
        context.server,
        message,
        Map.merge(context.assigns, assigns)
      )
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  end

  def read_resource(server, uri, options) when is_atom(server),
    do: read_resource(%Context{server: server}, uri, options)

  def read_resource(_, _, _), do: {:error, :invalid_target}

  defp invoke(context, name, arguments, options) do
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
      "params" =>
        Enum.reduce(
          [request_state: "requestState", input_responses: "inputResponses"],
          %{"name" => name, "arguments" => arguments, "_meta" => metadata},
          fn {option, key}, params ->
            if Keyword.has_key?(options, option),
              do: Map.put(params, key, options[option]),
              else: params
          end
        )
    }

    case Dispatcher.call_tool_request(
           context.server,
           message,
           Map.merge(context.assigns, options[:assigns])
         ) do
      {:ok, _form, _state} = reply -> reply
      {:ok, _result} = reply -> reply
      {:stream, execution} -> collect_stream(execution, options)
      {:error, _reason} = error -> error
    end
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
      {:ok, result, _} -> {:ok, result}
      {:input, form, state, _fields, _} -> {:ok, form, state}
      {:input_error, reason, _} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      {:failed, kind, reason, stack, _} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp validate_options(options) do
    if Keyword.keyword?(options) and
         Enum.all?(options, fn {key, _} ->
           key in [:assigns, :on_progress, :timeout, :request_state, :input_responses]
         end) do
      options = Keyword.merge([assigns: %{}, on_progress: nil, timeout: 5_000], options)

      cond do
        not (is_integer(options[:timeout]) and options[:timeout] > 0) ->
          {:error, :invalid_timeout}

        not (is_nil(options[:on_progress]) or is_function(options[:on_progress], 1)) ->
          {:error, :invalid_on_progress}

        true ->
          {:ok, options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_server(server) do
    if is_atom(server) and Code.ensure_loaded?(server) and
         function_exported?(server, :__portico__, 1),
       do: :ok,
       else: {:error, :invalid_server}
  end

  defp validate_assigns(assigns) do
    if is_map(assigns) and not is_struct(assigns) and Enum.all?(Map.keys(assigns), &is_atom/1),
      do: :ok,
      else: {:error, :invalid_assigns}
  end
end
