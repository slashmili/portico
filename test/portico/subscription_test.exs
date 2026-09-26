defmodule Portico.SubscriptionTest do
  use ExUnit.Case, async: true
  alias Portico.Protocol.Dispatcher
  alias Portico.Subscription.Runner

  defmodule Server do
    use Portico.Server, name: "subscriptions", version: "1"
    @impl true
    def handle_subscribe(filter, request) do
      send(request.assigns.observer, {:worker, self(), request})

      if request.assigns[:probe_init] do
        send(
          request.assigns.observer,
          {:init_send, Portico.Subscription.send({:resource_updated, "company://status"})}
        )
      end

      case request.assigns[:init] do
        nil -> {:ok, filter, 0}
        :block -> Process.sleep(:infinity)
        value -> value
      end
    end

    @impl true
    def handle_info({:update, uri}, count) do
      with :ok <- Portico.Subscription.send({:resource_updated, uri}) do
        {:noreply, count + 1}
      end
    end

    def handle_info({:probe, observer}, count) do
      send(observer, {:invalid_send, Portico.Subscription.send({:resource_updated, "relative"})})
      send(observer, {:unsupported_send, Portico.Subscription.send(:invalid)})

      task =
        Task.async(fn -> Portico.Subscription.send({:resource_updated, "company://status"}) end)

      send(observer, {:child_send, Task.await(task)})
      {:noreply, count}
    end

    def handle_info(:old_notify, state),
      do: {:notify, {:resource_updated, "company://status"}, state}

    def handle_info(:stop, state), do: {:stop, :normal, state}
    def handle_info(:crash, _), do: raise("private failure")
    def handle_info(:bad, _), do: :invalid
    def handle_info(:error, _), do: {:error, :application_error}
    def handle_info(_, state), do: {:noreply, state}
  end

  defmodule Unsupported do
    use Portico.Server, name: "unsupported", version: "1"
  end

  defp message(filter) do
    %{
      "jsonrpc" => "2.0",
      "id" => "sub-1",
      "method" => "subscriptions/listen",
      "params" => %{
        "notifications" => filter,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp execution(assigns \\ %{}) do
    {:subscription, execution} =
      Dispatcher.dispatch(
        Server,
        message(%{"resourceSubscriptions" => ["company://status"]}),
        Map.put(assigns, :observer, self())
      )

    execution
  end

  test "validates filters and advertises only supported subscriptions" do
    for filter <- [
          nil,
          [],
          %{"resourceSubscriptions" => "bad"},
          %{"resourceSubscriptions" => ["relative"]},
          %{"toolsListChanged" => 1}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Server, message(filter))
    end

    assert {:reply, %{"error" => %{"code" => -32601}}} =
             Dispatcher.dispatch(Unsupported, message(%{}))

    assert {:subscription, %{filter: %{resource_subscriptions: []}}} =
             Dispatcher.dispatch(Server, message(%{"toolsListChanged" => true}))

    discover = Map.put(message(%{}), "method", "server/discover")

    assert {:reply, %{"result" => %{"capabilities" => %{"resources" => %{"subscribe" => true}}}}} =
             Dispatcher.dispatch(Server, discover)
  end

  test "acknowledges before updates, filters URIs and stops cleanly" do
    execution = execution()
    parent = self()

    task =
      Task.async(fn ->
        Runner.run(
          execution,
          [],
          fn event, acc ->
            send(parent, {:event, event})
            {:ok, [event | acc]}
          end,
          :infinity
        )
      end)

    assert_receive {:worker, worker, %{server: Server}}
    monitor = Process.monitor(worker)
    send(worker, :ignored)
    send(worker, {:update, "company://other"})
    send(worker, {:update, "company://status"})
    send(worker, :stop)

    assert {:ok, [{:resource_updated, "company://status"}, {:ack, ["company://status"]}]} =
             Task.await(task)

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "explicit sends are callback-local and rejected sends do not end the subscription" do
    assert {:error, :not_subscription_worker} =
             Portico.Subscription.send({:resource_updated, "company://status"})

    execution = execution(%{probe_init: true})

    task =
      Task.async(fn ->
        Runner.run(execution, [], fn event, acc -> {:ok, acc ++ [event]} end, 1000)
      end)

    assert_receive {:worker, worker, _}
    assert_receive {:init_send, {:error, :not_subscription_worker}}
    send(worker, {:probe, self()})
    send(worker, {:update, "company://status"})
    send(worker, :stop)
    assert_receive {:invalid_send, {:error, :invalid_notification}}
    assert_receive {:unsupported_send, {:error, :unsupported_message}}
    assert_receive {:child_send, {:error, :not_subscription_worker}}

    assert {:ok, [{:ack, ["company://status"]}, {:resource_updated, "company://status"}]} =
             Task.await(task)
  end

  test "simultaneous subscriptions keep sends on their own stream" do
    subscriptions =
      for uri <- ["company://status", "company://other"] do
        execution = %{execution() | filter: %{resource_subscriptions: [uri]}}

        task =
          Task.async(fn ->
            Runner.run(execution, [], fn event, acc -> {:ok, acc ++ [event]} end, 1000)
          end)

        assert_receive {:worker, worker, _}
        {uri, task, worker}
      end

    for {_, _, worker} <- subscriptions do
      send(worker, {:update, "company://status"})
      send(worker, {:update, "company://other"})
      send(worker, :stop)
    end

    for {uri, task, _} <- subscriptions do
      assert {:ok, [{:ack, [^uri]}, {:resource_updated, ^uri}]} = Task.await(task)
    end
  end

  test "accepted subset controls notifications, including an empty subset" do
    for uris <- [["company://status", "company://status"], []] do
      execution = execution(%{init: {:ok, %{resource_subscriptions: uris}, 0}})

      execution = %{
        execution
        | filter: %{resource_subscriptions: ["company://status", "company://other"]}
      }

      task =
        Task.async(fn ->
          Runner.run(execution, [], fn event, acc -> {:ok, acc ++ [event]} end, 1000)
        end)

      assert_receive {:worker, worker, _}
      send(worker, {:update, "company://other"})
      send(worker, {:update, "company://status"})
      send(worker, :stop)

      expected =
        if uris == [],
          do: [{:ack, []}],
          else: [{:ack, ["company://status"]}, {:resource_updated, "company://status"}]

      assert {:ok, ^expected} = Task.await(task)
    end
  end

  test "rejects malformed or unrequested accepted filters before acknowledgement" do
    for filter <- [
          nil,
          %{},
          %{"resource_subscriptions" => []},
          %{resource_subscriptions: "company://status"},
          %{resource_subscriptions: ["company://unrequested"]},
          %{resource_subscriptions: [nil]},
          %{resource_subscriptions: [], tools_list_changed: true}
        ] do
      assert {:error, :invalid_subscription_filter, []} =
               Runner.run(
                 execution(%{init: {:ok, filter, 0}}),
                 [],
                 fn event, acc -> {:ok, [event | acc]} end,
                 1000
               )

      assert_receive {:worker, worker, _}
      refute Process.alive?(worker)
    end
  end

  test "callback errors are tuples and workers are cleaned up" do
    for {message, reason} <- [
          {:crash, :callback_failed},
          {:bad, :invalid_callback_return},
          {:old_notify, :invalid_callback_return},
          {:error, :application_error},
          {{:update, "bad"}, :invalid_notification}
        ] do
      execution = execution()
      task = Task.async(fn -> Runner.run(execution, nil, fn _, acc -> {:ok, acc} end, 1000) end)
      assert_receive {:worker, worker, _}
      send(worker, message)
      assert {:error, ^reason, nil} = Task.await(task)
      refute Process.alive?(worker)
    end

    for {init, reason} <- [
          {:invalid, :invalid_callback_return},
          {{:error, :denied}, :denied},
          {:block, :timeout}
        ] do
      assert {:error, ^reason, nil} =
               Runner.run(execution(%{init: init}), nil, fn _, acc -> {:ok, acc} end, 20)

      assert_receive {:worker, worker, _}
      refute Process.alive?(worker)
    end
  end

  test "timeout closes acknowledged streams; disconnect during heartbeat cleans up" do
    assert {:ok, nil} = Runner.run(execution(), nil, fn _, acc -> {:ok, acc} end, 20)
    assert_receive {:worker, worker, _}
    refute Process.alive?(worker)

    assert {:closed, [:ack]} =
             Runner.run(
               execution(),
               [],
               fn
                 {:ack, _}, acc -> {:ok, [:ack | acc]}
                 :heartbeat, acc -> {:error, acc}
               end,
               :infinity
             )

    assert_receive {:worker, worker, _}
    refute Process.alive?(worker)
  end

  test "disconnect while sending ACK or an update cleans up" do
    assert {:closed, nil} =
             Runner.run(execution(), nil, fn _, acc -> {:error, acc} end, :infinity)

    assert_receive {:worker, worker, _}
    refute Process.alive?(worker)
    execution = execution()

    task =
      Task.async(fn ->
        Runner.run(
          execution,
          nil,
          fn
            {:ack, _}, acc -> {:ok, acc}
            _, acc -> {:error, acc}
          end,
          :infinity
        )
      end)

    assert_receive {:worker, worker, _}
    send(worker, {:update, "company://status"})
    assert {:closed, nil} = Task.await(task)
    refute Process.alive?(worker)
  end

  test "SSE emits correlated ACK, update and final response" do
    execution = execution(%{init: {:ok, %{resource_subscriptions: ["company://status"]}, 0}})

    execution = %{
      execution
      | filter: %{resource_subscriptions: ["company://status", "company://other"]}
    }

    parent = self()

    task =
      Task.async(fn ->
        conn = Portico.Transport.Subscription.call(Plug.Test.conn(:post, "/mcp"), execution, 1000)
        send(parent, {:body, conn.resp_body})
      end)

    assert_receive {:worker, worker, _}
    send(worker, {:update, "company://status"})
    send(worker, :stop)
    Task.await(task)
    assert_receive {:body, body}
    events = for "data: " <> data <- String.split(body, "\n"), do: JSON.decode!(data)
    assert [ack, update, final] = events
    assert ack["method"] == "notifications/subscriptions/acknowledged"
    assert ack["params"]["notifications"] == %{"resourceSubscriptions" => ["company://status"]}
    assert update["params"]["uri"] == "company://status"
    assert final["result"]["resultType"] == "complete"

    for event <- events do
      fields = event["params"] || event["result"]
      assert fields["_meta"]["io.modelcontextprotocol/subscriptionId"] == "sub-1"
    end
  end

  test "callback pairs are checked during compilation" do
    for callback <- [
          "def handle_subscribe(_, _), do: {:ok, nil}",
          "def handle_info(_, state), do: {:noreply, state}"
        ] do
      assert_raise CompileError, ~r/require both/, fn ->
        Code.compile_string("""
        defmodule IncompleteSubscription#{System.unique_integer([:positive])} do
          use Portico.Server, name: "incomplete", version: "1"
          #{callback}
        end
        """)
      end
    end
  end

  @tag capture_log: true
  test "Plug routes subscriptions and sanitizes callback errors" do
    options = Portico.Plug.init(server: Server, assigns: [:observer, :init])

    conn =
      Plug.Test.conn(:post, "/mcp", JSON.encode!(message(%{})))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "subscriptions/listen")
      |> Plug.Conn.assign(:observer, self())
      |> Plug.Conn.assign(:init, {:error, :private_reason})
      |> Portico.Plug.call(options)

    assert conn.status == 200
    assert conn.halted
    refute conn.resp_body =~ "private_reason"
    assert conn.resp_body =~ "Internal error"
  end

  test "Plug validates subscription timeout at init" do
    assert Portico.Plug.init(server: Server).subscription_timeout == :infinity
    assert Portico.Plug.init(server: Server, subscription_timeout: 10).subscription_timeout == 10

    for bad <- [0, -1, nil, "100"] do
      assert_raise ArgumentError, fn ->
        Portico.Plug.init(server: Server, subscription_timeout: bad)
      end
    end
  end
end
