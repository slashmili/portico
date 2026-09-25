# Test-only routes exercise the same greeting with and without an override.
defmodule PorticoExample.RestartDefault do
  use Portico.Tool, input_schema: %{type: "object"}
  @impl true
  defdelegate call(arguments, request), to: PorticoExample.Tools.Greet
  @impl true
  defdelegate handle_input(answer, state, request), to: PorticoExample.Tools.Greet
end

defmodule PorticoExample.RestartServer do
  use Portico.Server, name: "restart-test", version: "1"
  tool "default", PorticoExample.RestartDefault
  tool "override", PorticoExample.Tools.Greet
end

Application.put_env(
  :portico,
  PorticoExample.RestartServer,
  Application.fetch_env!(:portico, PorticoExample.MCP)
)

{:ok, listener} =
  Bandit.start_link(
    plug: {Portico.Plug, server: PorticoExample.RestartServer},
    ip: {127, 0, 0, 1},
    port: 0
  )

{:ok, {_address, port}} = ThousandIsland.listener_info(listener)
File.write!(System.fetch_env!("PORTICO_E2E_READY_FILE"), Integer.to_string(port))
Process.sleep(:infinity)
