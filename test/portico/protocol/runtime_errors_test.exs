defmodule Portico.Protocol.RuntimeErrorsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  @moduletag capture_log: true
  alias Portico.{Request, Result}
  alias Portico.Protocol.{Dispatcher, Encoder}
  alias Portico.Stream.Runner

  defmodule Tool do
    use Portico.Tool, input_schema: %{}
    @impl true
    def call(%{"reply" => reply}, _), do: reply
    @impl true
    def handle_stream({:wait, observer}, _) do
      send(observer, {:worker, self()})
      Process.sleep(:infinity)
    end

    def handle_stream(reply, _), do: reply
  end

  defmodule Missing do
    use Portico.Tool, input_schema: %{}
    @impl true
    def call(_, _), do: {:noreply, "private", :stream}
  end

  defmodule Server do
    use Portico.Server, name: "runtime-errors", version: "1"
    tool "work", Tool
    tool "missing", Missing
  end

  defp message(name, args) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => args,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  test "dispatcher returns reasons for invalid callback returns and results" do
    for {reply, reason} <- [
          {:unexpected, :invalid_callback_return},
          {{:ok, "private"}, :invalid_callback_return},
          {{:ok, %Result{content: [%{type: "text", text: 1}]}}, :invalid_result}
        ] do
      assert Dispatcher.call_tool_request(Server, message("work", %{"reply" => reply}), %{}) ==
               {:error, reason}

      assert {:reply, %{"error" => %{"code" => -32603}}} =
               Dispatcher.dispatch(Server, message("work", %{"reply" => reply}))
    end

    assert Dispatcher.call_tool_request(Server, message("missing", %{}), %{}) ==
             {:error, :missing_stream_callback}
  end

  test "callback errors preserve their reason but never become client validation errors" do
    for reason <- [:invalid_text, :invalid_params, :unknown_tool, {:private, "detail"}] do
      args = %{"reply" => {:error, reason}}
      assert Dispatcher.call_tool(Server, "work", args, %Request{}) == {:error, reason}
      assert Portico.Test.call_tool(Server, "work", args) == {:error, reason}

      log =
        capture_log(fn ->
          assert {:reply, %{"error" => %{"code" => -32603, "message" => "Internal error"}}} =
                   Dispatcher.dispatch(Server, message("work", args))
        end)

      assert log =~ "Portico tool callback failed"
      assert log =~ inspect(reason)
    end
  end

  test "direct invocation and encoding reject bad input without exceptions" do
    for {name, args, request} <- [
          {"work", [], %Request{}},
          {42, %{}, %Request{}},
          {"work", %{}, nil},
          {"work", %{atom: true}, %Request{}}
        ] do
      assert Dispatcher.call_tool(Server, name, args, request) == {:error, :invalid_params}
    end

    assert Encoder.tool_result("private") == {:error, :invalid_result}
  end

  test "stream runner returns failure reasons and stops timed-out workers" do
    emit = fn _, acc -> {:ok, acc} end

    for {data, reason} <- [
          {{:ok, "private"}, :invalid_callback_return},
          {{:ok, %Result{content: ["private"]}}, :invalid_result},
          {{:wait, self()}, :timeout}
        ] do
      execution = %{module: Tool, data: data, request: %Request{}}
      assert Runner.run(execution, :acc, emit, 100) == {:error, reason, :acc}
    end

    assert_received {:worker, worker}
    refute Process.alive?(worker)
  end
end
