defmodule Portico.ToolTest do
  use ExUnit.Case, async: true

  test "tool options reject invalid metadata and a module-owned name" do
    for {options, message} <- [
          {[], "expected :input_schema to be a plain map"},
          {[input_schema: true], "expected :input_schema to be a plain map"},
          {[input_schema: %Portico.Request{}], "expected :input_schema to be a plain map"},
          {[input_schema: %{}, description: nil], "expected :description to be a UTF-8 string"},
          {[input_schema: %{}, description: <<255>>],
           "expected :description to be a UTF-8 string"},
          {[input_schema: %{}, name: "add"], "unknown tool option :name"},
          {[input_schema: %{}, typo: true], "unknown tool option :typo"},
          {[input_schema: %{}, input_schema: %{}], "duplicate tool option :input_schema"},
          {%{}, "expected tool options to be a keyword list"}
        ] do
      error =
        assert_raise CompileError, fn ->
          compile_body(
            quote do
              use Portico.Tool, unquote(Macro.escape(options))
              @impl true
              def call(_arguments, request), do: {:reply, Portico.Result.text("ok"), request}
            end
          )
        end

      assert error.description == message
    end
  end

  test "a tool must implement public call/2" do
    error =
      assert_raise CompileError, fn ->
        compile_body(
          quote do
            use Portico.Tool, input_schema: %{}
          end
        )
      end

    assert error.description == "Portico.Tool requires a public call/2 callback"
  end

  defp compile_body(body) do
    module = Module.concat(__MODULE__, "Declaration#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          unquote(body)
        end
      end
    )
  end
end
