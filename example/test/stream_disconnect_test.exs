defmodule PorticoExample.StreamDisconnectTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  defmodule Silent do
    use Portico.Tool, input_schema: %{}
    @impl true
    def call(_, _), do: {:noreply, nil, :stream}
    @impl true
    def handle_stream(_, stream) do
      send(stream.request.assigns.observer, {:silent_worker, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule Server do
    use Portico.Server, name: "disconnect", version: "1"
    tool "silent", Silent
  end

  defmodule Endpoint do
    def init(observer), do: observer

    def call(conn, observer) do
      conn
      |> Plug.Conn.assign(:observer, observer)
      |> Portico.Plug.call(Portico.Plug.init(server: Server, assigns: [:observer]))
    end
  end

  test "closing a real HTTP connection stops a worker that never emits progress" do
    listener = start_supervised!({Bandit, plug: {Endpoint, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "silent",
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\n",
        "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n",
        "Mcp-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: silent\r\n",
        "Content-Length: #{byte_size(body)}\r\n\r\n",
        body
      ])

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "200"
    assert_receive {:silent_worker, worker}, 2_000
    monitor = Process.monitor(worker)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
  end
end
