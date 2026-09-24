defmodule PorticoExample.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:portico_example, :start_server) do
        [
          {Bandit,
           plug: PorticoExample.Router,
           ip: {127, 0, 0, 1},
           port: Application.fetch_env!(:portico_example, :port)}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: PorticoExample.Supervisor)
  end
end
