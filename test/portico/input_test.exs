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
