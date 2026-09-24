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
          {:ok, Portico.Result.text("#{a + b}")}
        end
      end

  The server supplies the exposed name with `tool "add", MyApp.MCP.Tools.Add`.
  A tool module can be reused under different names or by multiple servers.

  `:input_schema` must be a plain map; `:description` is an optional UTF-8
  string. Schema contents are preserved and are not yet validated against JSON
  Schema. Every tool must implement a public `call/2` callback. Use
  `Portico.Test.call_tool/4` to invoke it through the dispatcher, which checks
  the callback's return shape. Protocol calls also validate envelopes and core
  metadata and encode completed text results. `Portico.Plug` serves HTTP requests;
  schema validation is not implemented yet.

  The request supplies assigns and client metadata; callbacks do not return it.
  `:ok` means a result was produced. The result's `is_error` flag distinguishes
  successful execution from an expected tool failure.

  Expected tool failures use the same callback shape:

      {:ok, Portico.Result.error("Provide a valid date.")}

  This returns a completed result with `isError: true`. Unexpected callback
  exceptions remain generic protocol errors over HTTP and propagate in tests.
  """

  @doc "Handles tool arguments with application context and returns a completed result."
  @callback call(map(), Portico.Request.t()) ::
              {:ok, Portico.Result.t()}

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

    metadata = Module.get_attribute(env.module, :portico_tool_metadata)

    quote do
      @doc false
      def __portico_tool__, do: unquote(Macro.escape(metadata))
    end
  end
end
