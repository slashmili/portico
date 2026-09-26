defmodule PorticoExample.Tools.Summarize do
  use Portico.Tool,
    description: "Return the count and sum of a list of integers.",
    input_schema: %{
      type: "object",
      properties: %{numbers: %{type: "array", items: %{type: "integer"}}},
      required: ["numbers"],
      additionalProperties: false
    },
    output_schema: %{
      type: "object",
      properties: %{count: %{type: "integer", minimum: 0}, sum: %{type: "integer"}},
      required: ["count", "sum"],
      additionalProperties: false
    }

  @impl true
  def call(%{"numbers" => numbers}, _request) do
    {:ok, result} =
      Portico.Result.structured(%{
        count: length(numbers),
        sum: Enum.sum(Enum.map(numbers, &trunc/1))
      })

    {:ok, result}
  end
end
