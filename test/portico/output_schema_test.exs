defmodule Portico.OutputSchemaTest do
  use ExUnit.Case, async: true
  alias Portico.Protocol.Encoder

  defp compile_tool(schema) do
    module = Module.concat(__MODULE__, "Tool#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Tool,
            input_schema: %{type: "object"},
            output_schema: unquote(Macro.escape(schema))

          def call(_, _), do: Portico.Result.structured(nil)
        end
      end
    )

    module
  end

  test "rejects invalid declarations with output-specific compile errors" do
    for schema <- [
          nil,
          true,
          [],
          %{type: "invalid"},
          %{required: "wrong"},
          %{"type" => "integer", :type => "string"},
          %{default: self()},
          %{"$ref" => "https://example.invalid/schema"},
          %{"$schema" => "http://json-schema.org/draft-07/schema#"}
        ] do
      assert_raise CompileError, ~r/:output_schema/, fn -> compile_tool(schema) end
    end
  end

  test "supports arrays, scalar values and explicit null, without casts or defaults" do
    for {schema, value, invalid} <- [
          {%{type: "array", items: %{type: "integer"}}, [1, 2], ["1"]},
          {%{type: "integer"}, 2.0, "2"},
          {%{type: "boolean"}, false, 0},
          {%{type: "string"}, "ok", false},
          {%{type: "null"}, nil, "null"},
          {%{type: "object", properties: %{n: %{default: 2}}, required: ["n"]}, %{"n" => 3}, %{}}
        ] do
      module = compile_tool(schema)
      validator = module.__portico_output_validator__()
      {:ok, result} = Portico.Result.structured(value)
      assert {:ok, %{"structuredContent" => ^value}} = Encoder.tool_result(result, validator)
      {:ok, result} = Portico.Result.structured(invalid)
      assert Encoder.tool_result(result, validator) == {:error, :invalid_output}
      assert Encoder.tool_result(%Portico.Result{}, validator) == {:error, :invalid_output}
    end
  end

  test "empty output schemas still require structured content and tolerate opaque annotations" do
    module = compile_tool(%{"x-mcp-header" => "not an input parameter"})
    validator = module.__portico_output_validator__()
    assert {:ok, _} = Encoder.tool_result(%Portico.Result{structured_content: nil}, validator)
    assert Encoder.tool_result(%Portico.Result{}, validator) == {:error, :invalid_output}

    assert Encoder.tool_result(%Portico.Result{structured_content: self()}, validator) ==
             {:error, :invalid_result}
  end
end
