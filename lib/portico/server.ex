defmodule Portico.Server do
  @moduledoc """
  Declares a server's identity, tool routes, and resource routes.

      defmodule MyApp.MCP do
        use Portico.Server, name: "my-app", version: "1.0.0"

        tool "add", MyApp.MCP.Tools.Add
      end

  Inspect declarations with `info/1`, `tools/1`, `resources/1`, and `resource_templates/1`. Names are case-sensitive;
  duplicate tool names and malformed declarations raise compile-time errors.
  Server names and versions must be nonempty UTF-8 strings. Versions do not
  have to follow semantic versioning.

  Tool modules use `Portico.Tool` to define their metadata and callback.
  Invoke tools with `Portico.Test.call_tool/4`. The protocol dispatcher supports
  discovery, listing, and completed tool calls through `Portico.Plug`. Schema
  declarations are checked at compilation and arguments before tool execution.
  Resource modules use `Portico.Resource`; declare them with `resource/2` or `resource_template/2` and
  test reads with `Portico.Test.read_resource/3`.
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
      Module.register_attribute(__MODULE__, :portico_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :portico_resource_templates, accumulate: true)
      @portico_info Compiler.info!(unquote(options), __ENV__)
      import Portico.Server, only: [tool: 2, resource: 2, resource_template: 2]
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

  @doc "Routes a static absolute URI to a module using Portico.Resource."
  defmacro resource(uri, module) do
    quote do
      @portico_resources {Compiler.resource!(unquote(uri), unquote(module), __ENV__), __ENV__}
    end
  end

  @doc """
  Routes a URI template to a module using Portico.Resource.

  Supports simple variables occupying whole path segments, such as
  `company://handbook/{section}`. Other RFC 6570 expressions fail at compilation.
  Static routes take precedence; overlapping template matches return an error.
  """
  defmacro resource_template(uri_template, module) do
    quote do
      @portico_resource_templates {Compiler.resource_template!(
                                     unquote(uri_template),
                                     unquote(module),
                                     __ENV__
                                   ), __ENV__}
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

    resources =
      env.module
      |> Module.get_attribute(:portico_resources)
      |> Enum.reverse()
      |> Compiler.resource_catalog!()

    templates =
      env.module
      |> Module.get_attribute(:portico_resource_templates)
      |> Enum.reverse()
      |> Compiler.resource_template_catalog!()

    quote do
      @doc false
      def __portico__(:resource_templates), do: unquote(Macro.escape(templates))
      def __portico__(:info), do: unquote(Macro.escape(info))
      def __portico__(:tools), do: unquote(Macro.escape(tools))
      def __portico__(:resources), do: unquote(Macro.escape(resources))
    end
  end

  @doc "Returns the server's declared name and version."
  @spec info(module()) :: info()
  def info(server), do: server.__portico__(:info)

  @doc """
  Returns all declared tools sorted by name, including the implementing module
  and normalized, string-keyed JSON Schema.

  This is static inspection of application declarations. It does not apply
  authorization or represent a caller-specific protocol tool listing.
  """
  @spec tools(module()) :: [tool_definition()]
  def tools(server), do: server.__portico__(:tools)
  @doc "Returns static resource declarations sorted by URI, including their modules."
  @spec resources(module()) :: [map()]
  def resources(server), do: server.__portico__(:resources)

  @doc "Returns resource templates sorted by URI template, including their modules."
  @spec resource_templates(module()) :: [map()]
  def resource_templates(server), do: server.__portico__(:resource_templates)
end
