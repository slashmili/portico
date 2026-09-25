defmodule PorticoExample.Tools.Add do
  use Portico.Tool,
    description: "Add two integers.",
    input_schema: %{
      type: "object",
      properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
      required: ["a", "b"],
      additionalProperties: false
    }

  @impl true
  def call(%{"a" => a, "b" => b}, _request) do
    # JSON Schema integers include values such as 2.0. Portico validates but
    # does not coerce arguments, so normalize them here for integer output.
    {:ok, result} = Portico.Result.text(Integer.to_string(trunc(a) + trunc(b)))
    {:ok, result}
  end
end
