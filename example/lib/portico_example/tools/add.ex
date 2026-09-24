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
  def call(%{"a" => a, "b" => b}, request) when is_integer(a) and is_integer(b) do
    {:reply, Portico.Result.text(Integer.to_string(a + b)), request}
  end
end
