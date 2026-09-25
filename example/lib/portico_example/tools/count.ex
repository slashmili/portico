defmodule PorticoExample.Tools.Count do
  use Portico.Tool,
    description: "Count to a number, streaming progress for counts above one.",
    input_schema: %{
      type: "object",
      properties: %{to: %{type: "integer", minimum: 1, maximum: 20}},
      required: ["to"],
      additionalProperties: false
    }

  @impl true
  def call(%{"to" => to}, _request) when to == 1, do: {:ok, Portico.Result.text("1")}
  def call(%{"to" => to}, _request), do: {:noreply, trunc(to), :stream}

  @impl true
  def handle_stream(to, stream) do
    for current <- 1..to do
      # A short pause makes progress visible in the runnable showcase.
      Process.sleep(100)
      Portico.Stream.send(stream, {:progress, current, total: to, message: "Counted #{current}"})
    end

    {:ok, Portico.Result.text(Integer.to_string(to))}
  end
end
