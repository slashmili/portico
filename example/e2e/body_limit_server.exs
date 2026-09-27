# Isolated loopback fixture, never mounted in the showcase.
Logger.configure(level: :error)

defmodule PorticoExample.BodyLimitTool do
  use Portico.Tool,
    input_schema: %{
      type: "object",
      properties: %{payload: %{type: "string"}, form: %{type: "boolean"}},
      required: ["payload"],
      additionalProperties: false
    }

  @impl true
  def call(%{"form" => true}, _) do
    {:ok, form} =
      Portico.Input.form("Continue?",
        schema: %{type: "object", properties: %{yes: %{type: "boolean"}}, required: ["yes"]}
      )

    {:ok, form, "size-probe"}
  end

  def call(%{"payload" => payload}, _) do
    {:ok, result} = Portico.Result.text(Integer.to_string(byte_size(payload)))
    {:ok, result}
  end

  @impl true
  def handle_input({:accept, %{"yes" => true}}, "size-probe", _) do
    {:ok, result} = Portico.Result.text("Resumed")
    {:ok, result}
  end
end

defmodule PorticoExample.BodyLimitMCP do
  use Portico.Server, name: "body-limit-probe", version: "1"
  tool "probe", PorticoExample.BodyLimitTool
end

defmodule PorticoExample.BodyLimitRouter do
  import Plug.Conn
  def init(opts), do: opts
  def call(%{request_path: "/health"} = conn, _), do: send_resp(conn, 200, "alive")
  def call(%{request_path: "/raw"} = conn, _), do: drain(conn, 0)

  def call(%{request_path: "/parsed"} = conn, _) do
    conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: JSON))
    Portico.Plug.call(conn, Portico.Plug.init(server: PorticoExample.BodyLimitMCP))
  end

  def call(%{request_path: "/larger"} = conn, _) do
    Portico.Plug.call(
      conn,
      Portico.Plug.init(server: PorticoExample.BodyLimitMCP, max_body_bytes: 4_000_000)
    )
  end

  def call(conn, _),
    do: Portico.Plug.call(conn, Portico.Plug.init(server: PorticoExample.BodyLimitMCP))

  # Default read_body length limits each read, not the total accumulated body.
  defp drain(conn, total) do
    case read_body(conn) do
      {:ok, body, conn} -> send_resp(conn, 200, Integer.to_string(total + byte_size(body)))
      {:more, body, conn} -> drain(conn, total + byte_size(body))
      {:error, _} -> send_resp(conn, 400, "read error")
    end
  end
end

Application.put_env(:portico, PorticoExample.BodyLimitMCP,
  elicitation_key: Base.encode64(:crypto.strong_rand_bytes(32))
)

{:ok, listener} =
  Bandit.start_link(plug: PorticoExample.BodyLimitRouter, ip: {127, 0, 0, 1}, port: 0)

{:ok, {_address, port}} = ThousandIsland.listener_info(listener)
File.write!(System.fetch_env!("PORTICO_BODY_LIMIT_READY_FILE"), Integer.to_string(port))
Process.sleep(:infinity)
