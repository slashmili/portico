defmodule Portico.ServerTest do
  use ExUnit.Case, async: true

  alias Portico.Server

  defmodule Add do
    use Portico.Tool,
      description: "Add a number",
      input_schema: %{type: "object", properties: %{a: %{type: "number"}}}

    @impl true
    def call(%{"a" => a}, request), do: {:reply, Portico.Result.text("#{a}"), request}
  end

  defmodule Zebra do
    use Portico.Tool, input_schema: %{"type" => "object"}

    @impl true
    def call(_arguments, request), do: {:reply, Portico.Result.text("zebra"), request}
  end

  defmodule Example do
    use Portico.Server, name: "example", version: "dev"

    alias Portico.ServerTest.{Add, Zebra}
    tool("zebra", Zebra)
    tool("add", Add)
  end

  defmodule Reused do
    use Portico.Server, name: "reused", version: "1"
    tool("sum", Portico.ServerTest.Add)
  end

  defmodule Empty do
    use Portico.Server, name: "empty", version: "1.0.0"
  end

  test "info returns the declared identity without requiring a semantic version" do
    assert Server.info(Example) == %{name: "example", version: "dev"}
  end

  test "tools are sorted by name and preserve schemas as declared" do
    assert Server.tools(Example) == [
             %{
               name: "add",
               module: Add,
               description: "Add a number",
               input_schema: %{type: "object", properties: %{a: %{type: "number"}}}
             },
             %{name: "zebra", module: Zebra, input_schema: %{"type" => "object"}}
           ]
  end

  test "server modules have independent identities and catalogs" do
    assert Server.info(Empty) == %{name: "empty", version: "1.0.0"}
    assert Server.tools(Empty) == []
    assert length(Server.tools(Example)) == 2
  end

  test "server identity requires nonempty UTF-8 name and version strings" do
    for options <- [
          [version: "1"],
          [name: "example"],
          [name: "", version: "1"],
          [name: "example", version: 1],
          [name: <<255>>, version: "1"]
        ] do
      assert_raise CompileError,
                   ~r/expected :(?:name|version) to be a nonempty UTF-8 string/,
                   fn ->
                     compile_body(quote do: use(Portico.Server, unquote(Macro.escape(options))))
                   end
    end
  end

  test "server options reject typos, duplicate keys, and non-keyword values" do
    for {options, message} <- [
          {[name: "example", version: "1", typo: true], "unknown server option :typo"},
          {[name: "a", name: "b", version: "1"], "duplicate server option :name"},
          {%{name: "example"}, "expected server options to be a keyword list"}
        ] do
      error =
        assert_raise CompileError, fn ->
          compile_body(quote do: use(Portico.Server, unquote(Macro.escape(options))))
        end

      assert error.description == message
    end
  end

  test "a tool module can be exposed under a different name on another server" do
    assert [%{name: "sum", module: Add}] = Server.tools(Reused)
    assert [%{name: "add"}, %{name: "zebra"}] = Server.tools(Example)
  end

  test "routes reject invalid names, missing modules, and the old inline form" do
    for {name, target, message} <- [
          {"", Add, "expected tool name to be a nonempty UTF-8 string"},
          {:add, Add, "expected tool name to be a nonempty UTF-8 string"},
          {"add", [input_schema: %{}], "expected a Portico.Tool module"},
          {"add", String, "expected String to use Portico.Tool"},
          {"add", Portico.MissingTool, "could not compile tool module Portico.MissingTool"}
        ] do
      error =
        assert_raise CompileError, fn ->
          compile_body(
            quote do
              use Portico.Server, name: "example", version: "1"
              tool(unquote(name), unquote(Macro.escape(target)))
            end
          )
        end

      assert error.description == message
    end
  end

  test "duplicate tool errors point to the second declaration" do
    module = unique_module()

    error =
      assert_raise CompileError, fn ->
        Code.compile_string(
          """
          defmodule #{inspect(module)} do
            use Portico.Server, name: "example", version: "1"
            tool "add", Portico.ServerTest.Add
            tool "add", Portico.ServerTest.Add
          end
          """,
          "duplicate_tools.ex"
        )
      end

    assert error.description == "duplicate tool name \"add\""
    assert error.file == "duplicate_tools.ex"
    assert error.line == 4
  end

  defp compile_body(body) do
    module = unique_module()

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          unquote(body)
        end
      end
    )
  end

  defp unique_module do
    Module.concat(__MODULE__, "Declaration#{System.unique_integer([:positive])}")
  end
end
