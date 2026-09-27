defmodule Portico.ToolTest do
  use ExUnit.Case, async: true

  test "tool options reject invalid metadata and a module-owned name" do
    for {options, message} <- [
          {[], "expected :input_schema to be a plain map"},
          {[input_schema: true], "expected :input_schema to be a plain map"},
          {[input_schema: %Portico.Request{}], "expected :input_schema to be a plain map"},
          {[input_schema: %{type: "object"}, description: nil],
           "expected :description to be a UTF-8 string"},
          {[input_schema: %{type: "object"}, description: <<255>>],
           "expected :description to be a UTF-8 string"},
          {[input_schema: %{type: "object"}, name: "add"], "unknown tool option :name"},
          {[input_schema: %{type: "object"}, elicitation_verifier: nil],
           "expected :elicitation_verifier to be an external function capture of arity 2"},
          {[input_schema: %{type: "object"}, elicitation_verifier: &String.trim/1],
           "expected :elicitation_verifier to be an external function capture of arity 2"},
          {[input_schema: %{type: "object"}, typo: true], "unknown tool option :typo"},
          {[input_schema: %{type: "object"}, input_schema: %{type: "object"}],
           "duplicate tool option :input_schema"},
          {%{}, "expected tool options to be a keyword list"}
        ] do
      error =
        assert_raise CompileError, fn ->
          compile_body(
            quote do
              use Portico.Tool, unquote(Macro.escape(options))
              @impl true
              def call(_arguments, _request), do: Portico.Result.text("ok")
            end
          )
        end

      assert error.description == message
    end
  end

  test "input schemas require an explicit object root" do
    for schema <- [
          %{},
          %{type: "array"},
          %{type: "string"},
          %{type: ["object"]},
          %{type: ["object", "null"]},
          %{properties: %{name: %{type: "string"}}},
          %{"$defs" => %{"args" => %{"type" => "object"}}, "$ref" => "#/$defs/args"}
        ] do
      error =
        assert_raise CompileError, fn ->
          compile_body(
            quote do
              use Portico.Tool, input_schema: unquote(Macro.escape(schema))
              @impl true
              def call(_, _), do: Portico.Result.text("ok")
            end
          )
        end

      assert error.description == ~s(input_schema must declare type: "object" at the root)
    end
  end

  test "a tool must implement public call/2" do
    error =
      assert_raise CompileError, fn ->
        compile_body(
          quote do
            use Portico.Tool, input_schema: %{type: "object"}
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
