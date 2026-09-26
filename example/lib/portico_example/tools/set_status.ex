defmodule PorticoExample.Tools.SetStatus do
  use Portico.Tool,
    description: "Change the demo status and notify resource subscribers.",
    input_schema: %{
      type: "object",
      properties: %{text: %{type: "string", minLength: 1}},
      required: ["text"],
      additionalProperties: false
    }

  @impl true
  def call(%{"text" => text}, _request) do
    :ok = PorticoExample.Status.set(text)
    {:ok, result} = Portico.Result.text("Status updated.")
    {:ok, result}
  end
end
