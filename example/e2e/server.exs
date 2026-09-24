# Mix starts the application in MIX_ENV=test without its normal listener.
# Let the OS choose a free port, then report it only after Bandit has started.
{:ok, listener} = Bandit.start_link(plug: PorticoExample.Router, ip: {127, 0, 0, 1}, port: 0)
{:ok, {_address, port}} = ThousandIsland.listener_info(listener)
File.write!(System.fetch_env!("PORTICO_E2E_READY_FILE"), Integer.to_string(port))
Process.sleep(:infinity)
