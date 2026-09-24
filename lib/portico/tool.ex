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
        def call(%{"a" => a, "b" => b}, request) do
          {:reply, Portico.Result.text("#{a + b}"), request}
        end
      end

  The server supplies the exposed name with `tool "add", MyApp.MCP.Tools.Add`.
  A tool module can be reused under different names or by multiple servers.

  `:input_schema` must be a plain map; `:description` is an optional UTF-8
  string. Schema contents are preserved and are not yet validated against JSON
  Schema. Every tool must implement a public `call/2` callback. Use
  `Portico.Test.call_tool/4` to invoke it through the dispatcher, which checks
  the callback's return shape. Protocol calls also validate envelopes and core
  metadata and encode completed text results. HTTP and schema validation are
  not implemented yet.
  """

  @doc "Handles tool arguments with application context and returns a completed result."
  @callback call(map(), Portico.Request.t()) ::
              {:reply, Portico.Result.t(), Portico.Request.t()}

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
