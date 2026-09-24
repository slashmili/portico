defmodule Portico.TestTest do
  use ExUnit.Case, async: true

  alias Portico.{Request, Result}
  import Portico.Test

  defmodule Add do
    use Portico.Tool,
      input_schema: %{
        type: "object",
        properties: %{a: %{type: "number"}, b: %{type: "number"}},
        required: ["a", "b"]
      }

    @impl true
    def call(%{"a" => a, "b" => b}, %Request{assigns: assigns})
        when map_size(assigns) == 0 do
      {:ok, Result.text("#{a + b}")}
    end
  end

  defmodule Observe do
    use Portico.Tool, input_schema: %{type: "object"}

    @impl true
    def call(arguments, request) do
      send(request.assigns.observer, {:called, arguments, request})
      {:ok, Result.text("ok")}
    end
  end

  defmodule Broken do
    use Portico.Tool, input_schema: %{}

    @impl true
    def call(%{"return" => value}, _request), do: value
    def call(%{"raise" => true}, _request), do: raise("tool failed")
  end

  defmodule Server do
    use Portico.Server, name: "test", version: "1"
    tool "add", Add
    tool "observe", Observe
    tool "broken", Broken
  end

  test "calls the declared tool and returns its result" do
    assert call_tool(Server, "add", %{"a" => 2, "b" => 3}) == Result.text("5")
  end

  test "each call receives fresh context with the supplied assigns" do
    for _ <- 1..2 do
      assert call_tool(Server, "observe", %{}, assigns: %{observer: self(), user_id: 42}) ==
               Result.text("ok")

      assert_received {:called, %{}, %Request{assigns: assigns}}
      assert assigns == %{observer: self(), user_id: 42}
    end
  end

  test "arguments allowed by the schema pass through unchanged" do
    arguments = %{"extra" => [1, "2"], "application_key" => true}
    call_tool(Server, "observe", arguments, assigns: %{observer: self()})
    assert_received {:called, ^arguments, %Request{}}
  end

  test "helper supplies validated protocol context" do
    call_tool Server, "observe", %{}, assigns: %{observer: self()}
    assert_received {:called, %{}, request}
    assert request.id == 1
    assert request.method == "tools/call"
    assert request.protocol_version == "2026-07-28"
    assert request.client_capabilities == %{}
    assert request.client_info == nil
  end

  test "helper validates custom context metadata before invoking a callback" do
    context = %Portico.Test.Context{server: Server, assigns: %{observer: self()}}

    for context <- [
          %{context | protocol_version: "old"},
          %{context | client_capabilities: nil},
          %{context | client_info: %{}}
        ] do
      assert_raise ArgumentError, fn ->
        call_tool context, "observe", %{}
      end

      refute_received {:called, _, _}
    end
  end

  test "helper passes declared client metadata into the request" do
    info = %{"name" => "test-client", "version" => "1"}
    caps = %{"elicitation" => %{"form" => %{}}}

    context = %Portico.Test.Context{
      server: Server,
      assigns: %{observer: self()},
      client_info: info,
      client_capabilities: caps
    }

    call_tool context, "observe", %{}
    assert_received {:called, %{}, request}
    assert request.client_info == info
    assert request.client_capabilities == caps
  end

  test "helper rejects result contents the protocol encoder cannot handle" do
    result = %Result{content: [%{type: "text", text: 42}]}

    assert_raise ArgumentError, ~r/invalid tool result content/, fn ->
      call_tool Server, "broken", %{"return" => {:ok, result}}
    end
  end

  test "the shared dispatcher passes context in and returns only the result" do
    request = %Request{assigns: %{observer: self()}}

    assert {:ok, result} =
             Portico.Protocol.Dispatcher.call_tool(Server, "observe", %{}, request)

    assert result == Result.text("ok")
    assert_received {:called, %{}, ^request}
  end

  test "unknown tool names do not invoke another tool" do
    assert_raise ArgumentError, ~r/unknown tool "missing"/, fn ->
      call_tool(Server, "missing", %{}, assigns: %{observer: self()})
    end

    refute_received {:called, _, _}
  end

  test "invalid callback return shapes fail without printing their payloads" do
    for reply <- [
          :ok,
          {:ok, "secret"},
          {:error, "secret"},
          {:ok, Result.text("secret"), %Request{}},
          {:reply, Result.text("secret"), %Request{}},
          {:reply, Result.text("secret"), %{}},
          {:stream, "secret", %Request{}}
        ] do
      error =
        assert_raise ArgumentError, fn ->
          call_tool(Server, "broken", %{"return" => reply})
        end

      assert error.message =~ "expected {:ok, %Portico.Result{}}"
      refute error.message =~ "secret"
    end
  end

  test "exceptions from a tool propagate" do
    assert_raise RuntimeError, "tool failed", fn ->
      call_tool(Server, "broken", %{"raise" => true})
    end
  end

  test "helper rejects invalid assigns and unknown options before invoking a tool" do
    for options <- [[assigns: []], [assigns: %{"user_id" => 42}], [assings: %{}]] do
      assert_raise ArgumentError, fn ->
        call_tool(Server, "observe", %{}, options)
      end
    end
  end

  test "arguments must be a plain map" do
    for arguments <- [nil, [], %Request{}, %{a: 2}] do
      assert_raise ArgumentError, ~r/invalid_params/, fn ->
        call_tool(Server, "add", arguments)
      end
    end
  end
end
