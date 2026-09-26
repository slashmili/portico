defmodule Portico.Server do
  @moduledoc """
  Declares a server's identity and tool, resource, and prompt routes.

      defmodule MyApp.MCP do
        use Portico.Server, name: "my-app", version: "1.0.0"

        tool "add", MyApp.MCP.Tools.Add
      end

  Inspect declarations with `info/1`, `tools/1`, `resources/1`, `resource_templates/1`, and `prompts/1`. Names are case-sensitive;
  duplicate tool names and malformed declarations raise compile-time errors.
  Server names and versions must be nonempty UTF-8 strings. Versions do not
  have to follow semantic versioning.

  Tool modules use `Portico.Tool` to define their metadata and callback.
  Invoke tools with `Portico.Test.call_tool/4`. The protocol dispatcher supports
  discovery, listing, and completed tool calls through `Portico.Plug`. Schema
  declarations are checked at compilation and arguments before tool execution.
  Resource modules use `Portico.Resource`; declare them with `resource/2` or `resource_template/2` and
  test reads with `Portico.Test.read_resource/3`. Prompt modules use
  `Portico.Prompt`; declare them with `prompt/2` and test with `Portico.Test.get_prompt/4`.

  ## Resource subscriptions

  Define both `handle_subscribe/2` and `handle_info/2` to advertise resource
  subscriptions. Portico starts one linked task per open `subscriptions/listen`
  HTTP response, invoking these callbacks in that task. The server module is not
  itself a GenServer. The filter is `%{resource_subscriptions: [uri]}` and the
  request contains fresh application assigns. Authenticate and authorize in
  `handle_subscribe/2` before registering with your application's event source.
  Return `{:ok, %{resource_subscriptions: accepted_uris}, state}` or
  `{:error, reason}`. Accepted URIs must be a subset of those requested; an empty
  list accepts none. Duplicates are removed. Invalid filters return an internal
  error before acknowledgement. Only accepted URIs are acknowledged and emitted.

  `handle_info/2` receives messages from that event source. Call
  `Portico.Subscription.send({:resource_updated, uri})` to emit an update, then
  return `{:noreply, state}` to keep waiting. Return `{:stop, :normal, state}` to
  close gracefully. Invalid returns,
  `{:error, reason}` and callback exceptions become sanitized protocol errors.
  Only accepted URIs are emitted; clients reread their contents after notification.

  Registration must belong to the callback process (for example, Registry or
  Phoenix.PubSub). It is killed on disconnect or timeout; use an event source
  that removes registrations when its process exits. There is no terminate
  callback, retained history or replay. Reconnect creates fresh state. The
  application owns authorization, resource limits and cross-node event delivery.
  Catalog-change notifications are not supported in this slice.
  """

  @callback handle_subscribe(%{resource_subscriptions: [String.t()]}, Portico.Request.t()) ::
              {:ok, %{resource_subscriptions: [String.t()]}, term()} | {:error, term()}
  @callback handle_info(term(), term()) ::
              {:noreply, term()}
              | {:stop, :normal, term()}
              | {:error, term()}
  @optional_callbacks handle_subscribe: 2, handle_info: 2

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
      @behaviour Portico.Server
      Module.register_attribute(__MODULE__, :portico_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :portico_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :portico_resource_templates, accumulate: true)
      Module.register_attribute(__MODULE__, :portico_prompts, accumulate: true)
      @portico_info Compiler.info!(unquote(options), __ENV__)
      import Portico.Server, only: [tool: 2, resource: 2, resource_template: 2, prompt: 2]
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

  @doc "Routes a nonempty UTF-8 prompt name to a module using Portico.Prompt."
  defmacro prompt(name, module) do
    quote do
      @portico_prompts {Compiler.prompt!(unquote(name), unquote(module), __ENV__), __ENV__}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    subscribe? = Module.defines?(env.module, {:handle_subscribe, 2})
    info? = Module.defines?(env.module, {:handle_info, 2})

    if subscribe? != info? do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "subscriptions require both handle_subscribe/2 and handle_info/2"
    end

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

    prompts =
      env.module
      |> Module.get_attribute(:portico_prompts)
      |> Enum.reverse()
      |> Compiler.prompt_catalog!()

    quote do
      @doc false
      def __portico__(:subscriptions), do: unquote(subscribe?)
      def __portico__(:prompts), do: unquote(Macro.escape(prompts))
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
  @doc "Returns prompt declarations sorted by name, including their modules."
  @spec prompts(module()) :: [map()]
  def prompts(server), do: server.__portico__(:prompts)
end
