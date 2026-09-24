defmodule Portico.SchemaErrorsTest do
  use ExUnit.Case, async: true
  alias Portico.Schema

  defp failure(schema, data) do
    {_, validator} = Schema.build!(schema, __ENV__)
    assert {:error, message} = Schema.validate(validator, data)
    String.replace_prefix(message, "Tool arguments do not match the input schema. ", "")
  end

  test "valid inputs succeed" do
    {_, validator} = Schema.build!(%{type: "integer"}, __ENV__)
    assert :ok = Schema.validate(validator, 2.0)
  end

  test "missing fields are sorted and nested paths include array indices" do
    schema = %{type: "object", required: ["z", "a"]}
    assert failure(schema, %{}) == ~s("/a": is required; "/z": is required)

    schema = %{properties: %{users: %{items: %{required: ["name"]}}}}
    assert failure(schema, %{"users" => [%{}]}) == ~s("/users/0/name": is required)
  end

  test "types and local references do not disclose submitted values" do
    schema = %{
      "$defs": %{value: %{type: ["integer", "null"]}},
      properties: %{value: %{"$ref" => "#/$defs/value"}}
    }

    assert failure(schema, %{"value" => "private-value"}) ==
             ~s("/value": expected integer or null)
  end

  test "extra properties and nested constraints identify the affected path" do
    assert failure(%{additionalProperties: false}, %{"extra" => "secret"}) ==
             ~s("/extra": is not allowed)

    schema = %{properties: %{tags: %{items: %{minLength: 2}}}}
    assert failure(schema, %{"tags" => [""]}) == ~s("/tags/0": does not satisfy minLength)
  end

  test "JSON pointer escaping and JSON quoting preserve unusual property names" do
    schema = %{properties: %{"a~/b\n" => %{type: "integer"}}}

    assert failure(schema, %{"a~/b\n" => "secret"}) ==
             JSON.encode!("/a~0~1b\n") <> ": expected integer"
  end

  test "root and alternative constraints do not report branches as required" do
    schema = %{anyOf: [%{type: "integer"}, %{type: "boolean"}]}
    assert failure(schema, "secret") == ~s("": does not satisfy anyOf)

    schema = %{if: %{type: "string"}, then: %{minLength: 10}, else: false}
    assert failure(schema, "secret") == ~s("": does not satisfy conditional)
  end

  test "schema-valued additional properties retain child errors" do
    schema = %{additionalProperties: %{type: "integer"}}
    assert failure(schema, %{"extra" => "secret"}) == ~s("/extra": expected integer)
  end
end
