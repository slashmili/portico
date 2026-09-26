defmodule PorticoExample.Resources.Welcome do
  use Portico.Resource, name: "welcome", mime_type: "text/plain"

  @impl true
  def read(_request) do
    {:ok, form} =
      Portico.Input.form("Choose a language",
        schema: %{
          type: "object",
          properties: %{language: %{type: "string", enum: ["en", "de"]}},
          required: ["language"]
        }
      )

    {:ok, form, "welcome:v1"}
  end

  @impl true
  def handle_input({:accept, %{"language" => language}}, "welcome:v1", _request) do
    text = if language == "de", do: "Willkommen", else: "Welcome"
    {:ok, content} = Portico.Resource.text(text)
    {:ok, content}
  end

  def handle_input(action, "welcome:v1", _request) when action in [:decline, :cancel] do
    {:ok, content} = Portico.Resource.text("Welcome")
    {:ok, content}
  end
end
