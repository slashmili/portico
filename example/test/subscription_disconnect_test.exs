defmodule PorticoExample.SubscriptionDisconnectTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  defmodule Server do
    use Portico.Server, name: "subscription-disconnect", version: "1"
    @impl true
    def handle_subscribe(filter, request) do
      {:ok, _} = Registry.register(PorticoExample.Events, :disconnect_test, nil)
      send(request.assigns.observer, {:silent_worker, self()})
      {:ok, filter, nil}
    end

    @impl true
    def handle_info(_, state), do: {:noreply, state}
  end

  defmodule Endpoint do
    def init(observer), do: observer

    def call(conn, observer) do
      conn
      |> Plug.Conn.assign(:observer, observer)
      |> Portico.Plug.call(Portico.Plug.init(server: Server, assigns: [:observer]))
    end
  end

  test "closing a subscription removes its application event registration" do
    listener = start_supervised!({Bandit, plug: {Endpoint, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "subscriptions/listen",
        "params" => %{
          "notifications" => %{"resourceSubscriptions" => ["company://status"]},
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
        "Mcp-Protocol-Version: 2026-07-28\r\nMcp-Method: subscriptions/listen\r\n",
        "Content-Length: #{byte_size(body)}\r\n\r\n",
        body
      ])

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "200"
    assert_receive {:silent_worker, worker}, 2_000
    assert [{^worker, nil}] = Registry.lookup(PorticoExample.Events, :disconnect_test)
    monitor = Process.monitor(worker)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    # Registry processes the worker exit independently of this test's monitor.
    assert Enum.reduce_while(1..100, false, fn _, _ ->
             if Registry.lookup(PorticoExample.Events, :disconnect_test) == [] do
               {:halt, true}
             else
               Process.sleep(10)
               {:cont, false}
             end
           end)
  end
end
