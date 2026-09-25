defmodule PorticoExample.Tools.ChooseColors do
  use Portico.Tool,
    description: "Choose one or two colors from a form.",
    input_schema: %{type: "object", properties: %{}, additionalProperties: false}

  @impl true
  def call(_arguments, _request) do
    {:ok, form} =
      Portico.Input.form("Pick one or two colors.",
        schema: %{
          type: "object",
          properties: %{
            colors: %{
              type: "array",
              title: "Choose colors",
              minItems: 1,
              maxItems: 2,
              items: %{
                anyOf: [
                  %{const: "#ff0000", title: "Red"},
                  %{const: "#00ff00", title: "Green"},
                  %{const: "#0000ff", title: "Blue"}
                ]
              }
            }
          },
          required: ["colors"]
        }
      )

    {:ok, form, "choose-colors:v1"}
  end

  @impl true
  def handle_input({:accept, %{"colors" => colors}}, "choose-colors:v1", _request) do
    {:ok, result} = Portico.Result.text("You chose #{Enum.join(colors, ", ")}.")
    {:ok, result}
  end

  def handle_input(:decline, "choose-colors:v1", _request) do
    {:ok, result} = Portico.Result.error("No colors selected.")
    {:ok, result}
  end

  def handle_input(:cancel, "choose-colors:v1", _request) do
    {:ok, result} = Portico.Result.text("Cancelled.")
    {:ok, result}
  end
end
