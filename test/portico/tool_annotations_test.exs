defmodule Portico.ToolAnnotationsTest do
  use ExUnit.Case, async: true

  defmodule ReadOnly do
    use Portico.Tool,
      input_schema: %{type: "object"},
      annotations: [read_only: true, open_world: false]

    @impl true
    def call(_, _) do
      {:ok, result} = Portico.Result.text("ok")
      {:ok, result}
    end
  end

  defmodule Mutating do
    use Portico.Tool,
      input_schema: %{type: "object"},
      annotations: [read_only: false, destructive: true, idempotent: false, open_world: true]

    @impl true
    def call(_, _), do: ReadOnly.call(nil, nil)
  end

  defmodule Empty do
    use Portico.Tool, input_schema: %{type: "object"}, annotations: []
    @impl true
    def call(_, _), do: ReadOnly.call(nil, nil)
  end

  defmodule Omitted do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(_, _), do: ReadOnly.call(nil, nil)
  end

  defmodule Server do
    use Portico.Server, name: "annotations", version: "1"
    tool "read", ReadOnly
    tool "write", Mutating
    tool "empty", Empty
    tool "omitted", Omitted
  end

  test "inspection preserves only supplied hints and execution is unchanged" do
    tools = Map.new(Portico.Server.tools(Server), &{&1.name, &1})
    assert tools["read"].annotations == %{read_only: true, open_world: false}

    assert tools["write"].annotations == %{
             read_only: false,
             destructive: true,
             idempotent: false,
             open_world: true
           }

    for name <- ["empty", "omitted"], do: refute(Map.has_key?(tools[name], :annotations))

    for name <- Map.keys(tools) do
      assert {:ok, %Portico.Result{content: [%{text: "ok"}]}} =
               Portico.Test.call_tool(Server, name, %{})
    end
  end

  test "listing maps hints to MCP names without adding defaults" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    {:reply, %{"result" => %{"tools" => tools}}} =
      Portico.Protocol.Dispatcher.dispatch(Server, request)

    tools = Map.new(tools, &{&1["name"], &1})
    assert tools["read"]["annotations"] == %{"readOnlyHint" => true, "openWorldHint" => false}

    assert tools["write"]["annotations"] == %{
             "readOnlyHint" => false,
             "destructiveHint" => true,
             "idempotentHint" => false,
             "openWorldHint" => true
           }

    for name <- ["empty", "omitted"], do: refute(Map.has_key?(tools[name], "annotations"))
  end

  test "invalid annotations fail at compilation" do
    cases =
      [
        {nil, "expected annotation options to be a keyword list"},
        {%{read_only: true}, "expected annotation options to be a keyword list"},
        {[read_only: true, read_only: false], "duplicate annotation option :read_only"},
        {[readOnlyHint: true], "unknown annotation option :readOnlyHint"},
        {[title: "Title"], "unknown annotation option :title"}
      ] ++
        for key <- [:read_only, :destructive, :idempotent, :open_world],
            value <- [nil, 0, "true"],
            do: {[{key, value}], "expected annotation #{inspect(key)} to be a boolean"}

    for {annotations, message} <- cases do
      module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

      error =
        assert_raise CompileError, fn ->
          Code.compile_quoted(
            quote do
              defmodule unquote(module) do
                use Portico.Tool,
                  input_schema: %{type: "object"},
                  annotations: unquote(Macro.escape(annotations))

                @impl true
                def call(_, _), do: Portico.Result.text("ok")
              end
            end
          )
        end

      assert error.description == message
    end
  end
end
