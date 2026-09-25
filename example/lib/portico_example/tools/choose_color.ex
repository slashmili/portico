defmodule PorticoExample.Tools.ChooseColor do
  use Portico.Tool,
    description: "Choose one color from a form.",
    input_schema: %{type: "object", properties: %{}, additionalProperties: false}

  @impl true
  def call(_arguments, _request) do
    {:ok, form} =
      Portico.Input.form("Pick your preferred color.",
        schema: %{
          type: "object",
          properties: %{
            color: %{
              type: "string",
              title: "Choose a color",
              oneOf: [
                %{const: "#ff0000", title: "Red"},
                %{const: "#00ff00", title: "Green"},
                %{const: "#0000ff", title: "Blue"}
              ]
            }
          },
          required: ["color"]
        }
      )

    {:ok, form, "choose-color:v1"}
  end

  @impl true
  def handle_input({:accept, %{"color" => color}}, "choose-color:v1", _request) do
    {:ok, result} = Portico.Result.text("You chose #{color}.")
    {:ok, result}
  end

  def handle_input(:decline, "choose-color:v1", _request) do
    {:ok, result} = Portico.Result.error("No color selected.")
    {:ok, result}
  end

  def handle_input(:cancel, "choose-color:v1", _request) do
    {:ok, result} = Portico.Result.text("Cancelled.")
    {:ok, result}
  end
end
