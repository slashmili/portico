defmodule PorticoExample.Resources.Status do
  use Portico.Resource,
    name: "status",
    description: "Current demo status; supports subscriptions."

  @impl true
  def read(_request) do
    {:ok, resource} = Portico.Resource.text(PorticoExample.Status.get())
    {:ok, resource}
  end
end
