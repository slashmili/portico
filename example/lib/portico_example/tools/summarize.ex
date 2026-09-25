defmodule PorticoExample.Tools.Summarize do
  use Portico.Tool,
    description: "Return the count and sum of a list of integers.",
    input_schema: %{
      type: "object",
      properties: %{numbers: %{type: "array", items: %{type: "integer"}}},
      required: ["numbers"],
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
