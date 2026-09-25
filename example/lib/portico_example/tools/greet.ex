defmodule PorticoExample.Tools.Greet do
  use Portico.Tool,
    description: "Ask for a name and greet the user.",
    input_schema: %{type: "object", properties: %{}, additionalProperties: false},
    elicitation_verifier: &__MODULE__.verify_input/2

  @impl true
  def call(_arguments, _request) do
    {:ok, form} =
      Portico.Input.form("What is your name?",
        schema: %{
          type: "object",
          properties: %{name: %{type: "string", minLength: 1}},
          required: ["name"]
        }
      )

    {:ok, form, "greet:v1"}
  end

  # An optional override: keep the default token checks, then enforce an
  # application-specific state version. Omit the option to use the default.
  def verify_input(token, request) do
    with {:ok, state} <- Portico.Elicitation.verify(token, request) do
      if state == "greet:v1", do: {:ok, state}, else: {:error, :invalid_greeting_state}
    end
  end

  @impl true
  def handle_input({:accept, %{"name" => name}}, "greet:v1", _request) do
    {:ok, result} = Portico.Result.text("Hello, #{name}!")
    {:ok, result}
  end

  def handle_input(:decline, "greet:v1", _request) do
    {:ok, result} = Portico.Result.error("Name declined.")
    {:ok, result}
  end

  def handle_input(:cancel, "greet:v1", _request) do
    {:ok, result} = Portico.Result.text("Cancelled.")
    {:ok, result}
  end
end
