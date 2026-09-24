defmodule Portico.Server do
  @moduledoc """
  Declares a server's identity and routes exposed tool names to tool modules.

      defmodule MyApp.MCP do
        use Portico.Server, name: "my-app", version: "1.0.0"

        tool "add", MyApp.MCP.Tools.Add
      end

  Inspect declarations with `info/1` and `tools/1`. Names are case-sensitive;
  duplicate tool names and malformed declarations raise compile-time errors.
  Server names and versions must be nonempty UTF-8 strings. Versions do not
  have to follow semantic versioning.

  Tool modules use `Portico.Tool` to define their metadata and callback.
  Execution, schema validation, and protocol discovery are not implemented yet.
  """

  alias Portico.Server.Compiler

  @type info :: %{name: String.t(), version: String.t()}
  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:module) => module(),
          required(:input_schema) => map(),
          optional(:description) => String.t()
        }

  @doc false
  defmacro __using__(options) do
    quote do
      Module.register_attribute(__MODULE__, :portico_tools, accumulate: true)
      @portico_info Compiler.info!(unquote(options), __ENV__)
      import Portico.Server, only: [tool: 2]
      @before_compile Portico.Server
    end
  end

  @doc """
  Routes a nonempty UTF-8 tool name to a module that uses `Portico.Tool`.

  Description and schema belong to the tool module. Inline metadata options
  are not supported. The module must be available at server compilation time.
  """
  defmacro tool(name, module) do
    quote do
      @portico_tools {Compiler.tool!(unquote(name), unquote(module), __ENV__), __ENV__}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    info = Module.get_attribute(env.module, :portico_info)

    tools =
      env.module
      |> Module.get_attribute(:portico_tools)
      |> Enum.reverse()
      |> Compiler.catalog!()

    quote do
      @doc false
      def __portico__(:info), do: unquote(Macro.escape(info))
      def __portico__(:tools), do: unquote(Macro.escape(tools))
    end
  end

  @doc "Returns the server's declared name and version."
  @spec info(module()) :: info()
  def info(server), do: server.__portico__(:info)

  @doc """
  Returns all declared tools sorted by name, including the implementing module
  and unchanged schema.

  This is static inspection of application declarations. It does not apply
  authorization or represent a caller-specific protocol tool listing.
  """
  @spec tools(module()) :: [tool_definition()]
  def tools(server), do: server.__portico__(:tools)
end
