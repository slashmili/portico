defmodule PorticoExample.Tools.Whoami do
  use Portico.Tool,
    description: "Show the user authenticated by the demo OAuth resource-server plug.",
    input_schema: %{type: "object", additionalProperties: false},
    annotations: [read_only: true, open_world: false]

  @impl true
  def call(_arguments, request) do
    {:ok, result} = Portico.Result.text("Authenticated as #{request.assigns.current_user.id}")
    {:ok, result}
  end
end
