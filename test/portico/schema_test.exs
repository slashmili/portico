defmodule Portico.SchemaTest do
  use ExUnit.Case, async: true

  defp compile_tool(schema) do
    module = Module.concat(__MODULE__, "Tool#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Tool, input_schema: unquote(Macro.escape(schema))
          @impl true
          def call(_, _), do: Portico.Result.text("ok")
        end
      end,
      "schema_declaration.ex"
    )

    module
  end

  test "normalizes atom keys and builds a reusable validator with local references" do
    schema = %{
      type: "object",
      properties: %{value: %{"$ref" => "#/$defs/count"}},
      "$defs": %{count: %{type: "integer", minimum: 1}},
      required: ["value"],
      additionalProperties: false
    }

    module = compile_tool(schema)
    normalized = module.__portico_tool__().input_schema
    assert normalized == JSON.decode!(JSON.encode!(schema))
    root = module.__portico_validator__()
    assert Portico.Schema.valid?(root, %{"value" => 2})
    refute Portico.Schema.valid?(root, %{"value" => 0})
    refute Map.has_key?(module.__portico_tool__(), :validator)
  end

  test "rejects invalid keyword values at declaration time" do
    for schema <- [
          %{type: "wrong"},
          %{required: "value"},
          %{minimum: "1"},
          %{properties: %{value: %{type: 42}}},
          %{required: ["x", "x"]}
        ] do
      error = assert_raise CompileError, fn -> compile_tool(schema) end
      assert error.file == "schema_declaration.ex"
      assert error.description =~ "invalid :input_schema"
    end
  end

  test "rejects ambiguous keys and non-JSON declaration values" do
    for schema <- [
          %{:type => "object", "type" => "string"},
          %{properties: %{:a => %{}, "a" => %{}}},
          %{default: self()},
          %{default: {:tuple}},
          %{default: %Portico.Request{}},
          %{default: :custom_atom},
          %{description: <<255>>},
          %{42 => "value"},
          %{<<255>> => "value"}
        ] do
      assert_raise CompileError, ~r/invalid :input_schema/, fn -> compile_tool(schema) end
    end
  end

  test "rejects unsupported dialects and unresolved references without fetching" do
    for schema <- [
          %{"$schema" => "http://json-schema.org/draft-07/schema#"},
          %{properties: %{x: %{"$schema" => "http://json-schema.org/draft-07/schema#"}}},
          %{"$ref" => "#/$defs/missing"},
          %{"$ref" => "https://example.invalid/schema.json"}
        ] do
      assert_raise CompileError, ~r/invalid :input_schema/, fn -> compile_tool(schema) end
    end
  end

  test "supports explicit dialect, boolean subschemas, and JSON annotation values" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{"blocked" => false},
      "default" => %{"$schema" => "literal data", "values" => [nil, true, false, 1.5]},
      "additionalProperties" => true
    }

    module = compile_tool(schema)
    assert module.__portico_tool__().input_schema == schema
    refute Portico.Schema.valid?(module.__portico_validator__(), %{"blocked" => 1})
  end

  test "compiled validators support composition, patterns, and 2020-12 tuple arrays" do
    module =
      compile_tool(%{
        type: "object",
        properties: %{
          code: %{allOf: [%{type: "string"}, %{pattern: "^[a-z]+$"}]},
          pair: %{
            type: "array",
            prefixItems: [%{type: "string"}, %{type: "integer"}],
            items: false
          }
        },
        required: ["code", "pair"],
        unevaluatedProperties: false
      })

    validator = module.__portico_validator__()
    assert Portico.Schema.valid?(validator, %{"code" => "abc", "pair" => ["x", 2]})
    refute Portico.Schema.valid?(validator, %{"code" => "ABC", "pair" => ["x", 2]})
    refute Portico.Schema.valid?(validator, %{"code" => "abc", "pair" => ["x", 2, 3]})

    refute Portico.Schema.valid?(validator, %{
             "code" => "abc",
             "pair" => ["x", 2],
             "extra" => true
           })
  end

  test "format remains an annotation and does not coerce data" do
    module =
      compile_tool(%{type: "object", properties: %{date: %{type: "string", format: "date"}}})

    data = %{"date" => "not-a-date"}
    assert Portico.Schema.valid?(module.__portico_validator__(), data)
  end
end
