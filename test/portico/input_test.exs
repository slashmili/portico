defmodule Portico.InputTest do
  use ExUnit.Case, async: true
  alias Portico.Input

  test "normalizes supported primitive fields" do
    for field <- [
          %{type: "string", minLength: 1, format: "email"},
          %{type: "number", minimum: 1},
          %{type: "integer", maximum: 10},
          %{type: "boolean", default: false}
        ] do
      assert {:ok, form} =
               Input.form("Question", schema: %{type: "object", properties: %{value: field}})

      assert form.schema["properties"]["value"]["type"] == field.type
    end
  end

  test "string enums preserve choices, labels and valid defaults" do
    field = %{
      type: "string",
      title: "Color",
      description: "Pick one",
      enum: ["red", "緑", "blue"],
      default: "緑"
    }

    assert {:ok, form} =
             Input.form("Choose",
               schema: %{type: "object", properties: %{color: field}, required: ["color"]}
             )

    assert form.schema["properties"]["color"] == %{
             "type" => "string",
             "title" => "Color",
             "description" => "Pick one",
             "enum" => ["red", "緑", "blue"],
             "default" => "緑"
           }
  end

  test "invalid enum choices and defaults are rejected" do
    for field <- [
          %{type: "string", enum: []},
          %{type: "string", enum: "red"},
          %{type: "string", enum: ["red", "red"]},
          %{type: "string", enum: ["red", 1]},
          %{type: "string", enum: [<<255>>]},
          %{type: "number", enum: [1, 2]},
          %{type: "string", enum: ["red"], default: "blue"},
          %{type: "string", enum: ["red"], minLength: 1},
          %{type: "string", enum: ["red"], oneOf: [%{const: "red", title: "Red"}]}
        ] do
      assert Input.form("Choose", schema: %{type: "object", properties: %{color: field}}) ==
               {:error, :invalid_schema}
    end
  end

  test "labeled choices preserve constants, titles and valid defaults" do
    choices = [%{const: "#ff0000", title: "Red"}, %{const: "#00ff00", title: "緑"}]

    for field <- [
          %{type: "string", oneOf: choices},
          %{type: "string", oneOf: choices, default: "#00ff00"}
        ] do
      assert {:ok, form} =
               Input.form("Color", schema: %{type: "object", properties: %{color: field}})

      assert form.schema["properties"]["color"]["oneOf"] == [
               %{"const" => "#ff0000", "title" => "Red"},
               %{"const" => "#00ff00", "title" => "緑"}
             ]
    end
  end

  test "malformed labeled choices and invalid defaults return schema errors" do
    for choices <- [
          [],
          "red",
          [true],
          [%{const: "red"}],
          [%{title: "Red"}],
          [%{const: 1, title: "One"}],
          [%{const: "red", title: 1}],
          [%{const: "red", title: <<255>>}],
          [%{const: "red", title: "Red", description: "extra"}],
          [%{const: "red", title: "Red"}, %{const: "red", title: "Another red"}]
        ] do
      assert Input.form("Color",
               schema: %{type: "object", properties: %{color: %{type: "string", oneOf: choices}}}
             ) == {:error, :invalid_schema}
    end

    for field <- [
          %{type: "string", oneOf: [%{const: "red", title: "Red"}], default: "Red"},
          %{type: "string", oneOf: [%{const: "red", title: "Red"}], minLength: 1},
          %{type: "integer", oneOf: [%{const: 1, title: "One"}]}
        ] do
      assert Input.form("Color", schema: %{type: "object", properties: %{color: field}}) ==
               {:error, :invalid_schema}
    end
  end

  test "invalid form declarations return errors" do
    for message <- [nil, 42, <<255>>],
        do: assert(Input.form(message, []) == {:error, :invalid_message})

    for options <- [nil, %{}, [], [schema: %{}, extra: true]],
        do: assert(Input.form("?", options) == {:error, :invalid_options})

    for schema <- [
          nil,
          %{},
          %{type: "array"},
          %{type: "object", properties: %{}, required: ["missing"]},
          %{type: "object", properties: %{x: %{type: "object"}}},
          %{type: "object", properties: %{x: true}},
          %{type: "object", properties: %{x: %{type: "string", format: "unknown"}}},
          %{type: "object", properties: %{x: %{type: "string", pattern: "x"}}}
        ] do
      assert Input.form("?", schema: schema) == {:error, :invalid_schema}
    end
  end
end
