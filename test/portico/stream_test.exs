defmodule Portico.StreamTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Portico.Test
  import Plug.Conn
  import Plug.Test
  alias Portico.{Result, Stream}
  alias Portico.Protocol.Dispatcher

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(%{"mode" => "reply"}, _request), do: Result.text("immediate")
    def call(arguments, _request), do: {:noreply, arguments, :stream}

    @impl true
    def handle_stream(arguments, stream) do
      if observer = stream.request.assigns[:observer], do: send(observer, {:worker, self()})

      case arguments["mode"] do
        "callback_error" ->
          {:error, {:invalid_text, "private detail"}}

        "bad_message" ->
          observe_send(stream, Stream.send(stream, arguments["message"]))

        "bad_progress" ->
          observe_send(
            stream,
            Stream.send(stream, {:progress, arguments["value"], arguments["options"]})
          )

        "foreign_progress" ->
          result = Task.async(fn -> Stream.send(stream, {:progress, 1}) end) |> Task.await()
          observe_send(stream, result)

        "pause" ->
          receive do
            :finish -> Result.text("finished")
          end

        "raise" ->
          raise "private exception"

        "invalid" ->
          {:ok, "private result"}

        "invalid_content" ->
          {:ok, %Result{content: [%{type: "text", text: 1}]}}

        "error" ->
          Result.error("expected failure")

        "wait" ->
          Process.sleep(:infinity)

        "duplicate" ->
          :ok = Stream.send(stream, {:progress, 1})
          result = Stream.send(stream, {:progress, 1})
          :ok = Stream.send(stream, {:progress, 2})
          observe_send(stream, result)

        _ ->
          Stream.send(stream, {:progress, 0.5, total: 2.0, message: "first\nline"})
          Stream.send(stream, {:progress, 2})
          Result.text("finished")
      end
    end

    defp observe_send(stream, result) do
      if observer = stream.request.assigns[:observer], do: send(observer, {:send_result, result})
      Result.text("handled")
    end
  end

  defmodule Missing do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(_, _), do: {:noreply, :data, :stream}
  end

  defmodule Server do
    use Portico.Server, name: "stream-test", version: "1"
    tool "work", Tool
    tool "missing", Missing
  end

  defp message(arguments, meta \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "work",
        "arguments" => arguments,
        "_meta" =>
          Map.merge(
            %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            },
            meta
          )
      }
    }
  end

  defp http(message) do
    conn(:post, "/mcp", JSON.encode!(message))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", "work")
    |> Portico.Plug.call(Portico.Plug.init(server: Server))
  end

  defp events(conn) do
    conn.resp_body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> JSON.decode!()))
  end

  test "one tool chooses either reply or streaming per invocation" do
    assert call_tool(Server, "work", %{"mode" => "reply"}) == Result.text("immediate")
    owner = self()

    {:ok, result} =
      call_tool Server, "work", %{},
        assigns: %{observer: owner},
        on_progress: fn progress -> send(owner, {:progress, progress}) end

    assert {:ok, result} == Result.text("finished")
    assert_received {:worker, worker}
    assert worker != owner
    refute Process.alive?(worker)
    assert_received {:progress, %{progress: 0.5, total: 2.0, message: "first\nline"}}
    assert_received {:progress, %{progress: 2}}
  end

  test "streaming HTTP sends ordered progress then one completed response" do
    for token <- ["token", 0] do
      conn = http(message(%{}, %{"progressToken" => token}))
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
      assert [first, second, final] = events(conn)
      assert first["method"] == "notifications/progress"

      assert first["params"] == %{
               "progressToken" => token,
               "progress" => 0.5,
               "total" => 2.0,
               "message" => "first\nline"
             }

      assert second["params"] == %{"progressToken" => token, "progress" => 2}
      assert final["id"] == 7
      assert final["result"]["resultType"] == "complete"
      assert final["result"]["content"] == [%{"type" => "text", "text" => "finished"}]
    end
  end

  test "no progress token means only the final response is emitted" do
    assert [final] = events(http(message(%{})))
    assert final["result"]["isError"] == false
  end

  test "invalid progress tokens fail before executing the tool" do
    for token <- [nil, true, 1.5, [], %{}] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Server, message(%{}, %{"progressToken" => token}), %{
                 observer: self()
               })

      refute_received {:worker, _}
    end
  end

  test "stream failures stay visible in helpers and sanitized over HTTP" do
    for mode <- ["raise", "invalid", "invalid_content"] do
      if mode == "raise" do
        assert_raise RuntimeError, fn -> call_tool Server, "work", %{"mode" => mode} end
      else
        reason = if mode == "invalid", do: :invalid_callback_return, else: :invalid_result
        assert call_tool(Server, "work", %{"mode" => mode}) == {:error, reason}
      end

      conn = http(message(%{"mode" => mode}, %{"progressToken" => "p"}))
      assert List.last(events(conn))["error"]["code"] == -32603
      refute conn.resp_body =~ "private"
    end
  end

  test "stream callback error reasons survive helper calls and stay out of HTTP responses" do
    assert call_tool(Server, "work", %{"mode" => "callback_error"}) ==
             {:error, {:invalid_text, "private detail"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = http(message(%{"mode" => "callback_error"}))
        assert [final] = events(conn)
        assert final["error"] == %{"code" => -32603, "message" => "Internal error"}
        refute conn.resp_body =~ "private detail"
      end)

    assert log =~ "Portico stream failed"
    assert log =~ "invalid_text"
  end

  test "expected stream errors remain completed tool results" do
    assert call_tool(Server, "work", %{"mode" => "error"}) ==
             Result.error("expected failure")

    assert [final] = events(http(message(%{"mode" => "error"})))
    assert final["result"]["isError"]
  end

  test "test helper timeout stops silent workers" do
    assert call_tool(Server, "work", %{"mode" => "wait"},
             assigns: %{observer: self()},
             timeout: 50
           ) ==
             {:error, :timeout}

    assert_received {:worker, worker}
    refute Process.alive?(worker)
  end

  test "stream return requires the optional callback" do
    assert call_tool(Server, "missing", %{}) == {:error, :missing_stream_callback}
  end

  test "invalid progress values and options return error tuples" do
    for {value, options, reason} <- [
          {"private", [], :invalid_progress},
          {true, [], :invalid_progress},
          {1, [total: nil], :invalid_total},
          {1, [message: 2], :invalid_message},
          {1, [message: <<255>>], :invalid_message},
          {1, nil, :invalid_options},
          {1, %{total: 2}, :invalid_options},
          {1, [:total], :invalid_options},
          {1, [unknown: "private"], :invalid_options}
        ] do
      assert call_tool(
               Server,
               "work",
               %{"mode" => "bad_progress", "value" => value, "options" => options},
               assigns: %{observer: self()}
             ) == Result.text("handled")

      assert_received {:send_result, {:error, ^reason}}
    end

    call_tool Server, "work", %{"mode" => "foreign_progress"}, assigns: %{observer: self()}
    assert_received {:send_result, {:error, :not_stream_worker}}
  end

  test "non-increasing updates are rejected and the stream can recover" do
    call_tool Server, "work", %{"mode" => "duplicate"}, assigns: %{observer: self()}
    assert_received {:send_result, {:error, :non_increasing_progress}}

    assert [first, second, final] =
             events(http(message(%{"mode" => "duplicate"}, %{"progressToken" => "p"})))

    assert first["params"]["progress"] == 1
    assert second["params"]["progress"] == 2
    assert final["result"]["isError"] == false
  end

  test "helper checks stream options before starting work" do
    for options <- [[timeout: 0], [timeout: :infinity], [on_progress: true]] do
      assert {:error, _reason} = call_tool(Server, "work", %{}, options)
    end

    assert_raise ArgumentError, fn -> Portico.Plug.init(server: Server, stream_timeout: 0) end
  end

  test "a failed consumer stops its worker" do
    assert_raise RuntimeError, "consumer failed", fn ->
      call_tool Server, "work", %{},
        assigns: %{observer: self()},
        on_progress: fn _ -> raise "consumer failed" end
    end

    assert_received {:worker, worker}
    refute Process.alive?(worker)
  end

  test "a killed request owner cannot leave its worker running" do
    observer = self()

    owner =
      spawn(fn ->
        call_tool Server, "work", %{"mode" => "wait"}, assigns: %{observer: observer}
      end)

    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "a quiet stream sends heartbeat comments and then completes" do
    {:stream, execution} =
      Dispatcher.dispatch(Server, message(%{"mode" => "pause"}), %{observer: self()})

    emit = fn :heartbeat, _ ->
      assert_received {:worker, worker}
      send(worker, :finish)
      {:ok, :heartbeat_seen}
    end

    assert {:ok, _, :heartbeat_seen} = Portico.Stream.Runner.run(execution, nil, emit, 3_000)
  end

  defmodule ClosingAdapter do
    defdelegate send_chunked(payload, status, headers), to: Plug.Adapters.Test.Conn
    def chunk(%{remaining: 0}, _), do: {:error, :closed}

    def chunk(payload, data) do
      Plug.Adapters.Test.Conn.chunk(%{payload | remaining: payload.remaining - 1}, data)
    end
  end

  test "disconnect during initial flush, progress, final result, or silence stops work" do
    for {mode, token, remaining} <- [
          {"normal", "p", 0},
          {"normal", "p", 1},
          {"normal", nil, 1},
          {"wait", nil, 1}
        ] do
      {:stream, execution} =
        Dispatcher.dispatch(Server, message(%{"mode" => mode}), %{observer: self()})

      execution = put_in(execution.request.progress_token, token)
      conn = conn(:post, "/mcp")
      {_, payload} = conn.adapter
      conn = %{conn | adapter: {ClosingAdapter, Map.put(payload, :remaining, remaining)}}
      assert Portico.Transport.SSE.call(conn, execution, 3_000).halted

      if remaining == 0 do
        refute_received {:worker, _}
      else
        assert_received {:worker, worker}
        refute Process.alive?(worker)
      end
    end
  end

  test "unsupported stream messages fail without exposing their payload" do
    for message <- [
          :unknown,
          {:unknown, "private-value"},
          {:progress},
          {:progress, 1, [], :extra}
        ] do
      assert call_tool(Server, "work", %{"mode" => "bad_message", "message" => message},
               assigns: %{observer: self()}
             ) == Result.text("handled")

      assert_received {:send_result, {:error, :unsupported_message}}
    end
  end

  test "invalid contexts and unavailable owners return errors" do
    assert Stream.send(nil, {:progress, 1}) == {:error, :invalid_stream}
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    stream = %Stream{request: %Portico.Request{}, owner: owner, worker: self(), ref: make_ref()}
    assert Stream.send(stream, {:progress, 1}) == {:error, :closed}
  end
end
