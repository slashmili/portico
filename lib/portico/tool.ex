defmodule Portico.Tool do
  @moduledoc ~S"""
  Defines a tool's metadata and application callback.

      defmodule MyApp.MCP.Tools.Add do
        use Portico.Tool,
          description: "Add two numbers",
          input_schema: %{
            type: "object",
            properties: %{a: %{type: "number"}, b: %{type: "number"}},
            required: ["a", "b"]
          }

        @impl true
        def call(%{"a" => a, "b" => b}, _request) do
          {:ok, result} = Portico.Result.text("#{a + b}")
          {:ok, result}
        end
      end

  The server supplies the exposed name with `tool "add", MyApp.MCP.Tools.Add`.
  A tool module can be reused under different names or by multiple servers.

  `:input_schema` must be a plain map; `:description` is an optional UTF-8
  string. Schemas are checked at compilation against Draft 2020-12 and built
  into an internal validator. Atom map keys are normalized recursively to strings;
  duplicate normalized keys and non-JSON values are rejected. Values such as
  types and required property names must be JSON strings, not atoms. Catalogs
  expose the normalized schema. JSV is an internal implementation detail.

  The initial dialect is `https://json-schema.org/draft/2020-12/schema`, also
  used when `$schema` is absent. Local references and bundled meta-schemas are
  available; no remote references are fetched. Unsupported dialects and unresolved
  references fail compilation. `format` and content keywords remain annotations,
  not assertions about string values or encoded content.

  Every tool must implement a public `call/2` callback. Use
  `Portico.Test.call_tool/4` to invoke it through the dispatcher, which checks
  the callback's return shape. Protocol calls also validate envelopes and core
  metadata and encode completed text results. `Portico.Plug` serves HTTP requests;
  arguments are checked against the compiled schema before the callback runs.
  Invalid arguments return a completed tool error with field paths and reasons;
  the callback is skipped. Paths are JSON-quoted JSON Pointers (`""` means the
  root), and submitted values are not included. Missing fields and type errors
  have specific messages; other constraints identify the failed schema keyword. Valid arguments are passed unchanged, without coercion
  or insertion of schema defaults. JSON Schema integers include values such
  as `2.0`, so callbacks should account for both Elixir numeric representations.

  The request supplies assigns and client metadata; callbacks do not return it.
  `:ok` means a result was produced. The result's `is_error` flag distinguishes
  successful execution from an expected tool failure.

  Expected tool failures use the same callback shape:

      {:ok, result} = Portico.Result.error("Provide a valid date.")
      {:ok, result}

  This returns a completed result with `isError: true`. Unexpected callback
  exceptions remain generic protocol errors over HTTP and propagate in tests.

  For streaming, return `{:noreply, data, :stream}` from `call/2` and implement
  the optional `handle_stream/2` callback:

      def call(%{"to" => to}, _request), do: {:noreply, to, :stream}

      def handle_stream(to, stream) do
        for n <- 1..to, do: Portico.Stream.send(stream, {:progress, n, total: to})
        {:ok, result} = Portico.Result.text("Finished")
        {:ok, result}
      end

  Each invocation chooses its response type. `call/2` runs in the request
  process; keep it short and put long-running work in `handle_stream/2`.
  Portico runs that callback in a linked task and provides the original request
  as `stream.request`. No GenServer, permanent tool process, or session is created.
  The data is an ordinary Elixir value and is not serialized or retained for retries.

  The callback must return `{:ok, %Portico.Result{}}`, including for expected
  failures. It cannot start another stream. Portico stops its task on timeout
  or detected disconnect. Detached work started by application code is outside
  this task's lifetime; cancellation does not undo effects already performed.
  """

  @doc "Handles tool arguments and chooses an immediate result or streaming work."
  @callback call(map(), Portico.Request.t()) ::
              {:ok, Portico.Result.t()} | {:noreply, term(), :stream}

  @doc "Runs request-scoped streaming work and returns the final result."
  @callback handle_stream(term(), Portico.Stream.t()) :: {:ok, Portico.Result.t()}
  @optional_callbacks handle_stream: 2

  @doc false
  defmacro __using__(options) do
    quote do
      @behaviour Portico.Tool
      @portico_tool_metadata Portico.Server.Compiler.tool_metadata!(unquote(options), __ENV__)
      @before_compile Portico.Tool
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:call, 2}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Portico.Tool requires a public call/2 callback"
    end

    {validator, metadata} =
      env.module |> Module.get_attribute(:portico_tool_metadata) |> Map.pop!(:validator)

    quote do
      @doc false
      def __portico_tool__, do: unquote(Macro.escape(metadata))

      @doc false
      def __portico_validator__, do: unquote(Macro.escape(validator))
    end
  end
end
