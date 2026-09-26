defmodule PorticoExample.Tools.SummarizeText do
  use Portico.Tool,
    description: "Ask the client's model to summarize text.",
    input_schema: %{
      type: "object",
      properties: %{text: %{type: "string", minLength: 1}},
      required: ["text"],
      additionalProperties: false
    }

  @impl true
  def call(%{"text" => text}, _request) do
    {:ok, input} = Portico.Input.sample("Summarize this:\n#{text}", max_tokens: 200)
    {:ok, input, "summarize:v1"}
  end

  @impl true
  def handle_input({:sample, %{text: text}}, "summarize:v1", _request) do
    {:ok, result} = Portico.Result.text(text)
    {:ok, result}
  end
end
