defmodule PorticoExample.Status do
  @moduledoc "Application-owned status and node-local event source for the subscription demo."
  use Agent

  def start_link(_), do: Agent.start_link(fn -> "Ready" end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)

  def set(text) do
    Agent.update(__MODULE__, fn _ -> text end)

    Registry.dispatch(PorticoExample.Events, :status, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:status_changed, "company://status"})
    end)

    :ok
  end
end
