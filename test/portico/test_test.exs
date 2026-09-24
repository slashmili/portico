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
    def call(%{"a" => a, "b" => b}, %Request{assigns: assigns} = request)
        when map_size(assigns) == 0 do
      {:reply, Result.text("#{a + b}"), request}
    end
  end

  defmodule Observe do
    use Portico.Tool, input_schema: %{type: "object"}

    @impl true
    def call(arguments, request) do
      send(request.assigns.observer, {:called, arguments, request})
      {:reply, Result.text("ok"), Request.assign(request, :called, true)}
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

  test "arguments pass through unchanged while schema validation is deferred" do
    arguments = %{"extra" => [1, "2"], :application_key => true}
    call_tool(Server, "observe", arguments, assigns: %{observer: self()})
    assert_received {:called, ^arguments, %Request{}}
  end

  test "the shared dispatcher preserves the request returned by the callback" do
    request = %Request{assigns: %{observer: self()}}

    assert {:reply, result, updated} =
             Portico.Protocol.Dispatcher.call_tool(Server, "observe", %{}, request)

    assert result == Result.text("ok")
    assert updated.assigns == %{observer: self(), called: true}
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
          {:reply, "secret", %Request{}},
          {:reply, Result.text("secret"), %{}},
          {:stream, "secret", %Request{}}
        ] do
      error =
        assert_raise ArgumentError, fn ->
          call_tool(Server, "broken", %{"return" => reply})
        end

      assert error.message =~ "expected {:reply, %Portico.Result{}, %Portico.Request{}}"
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
    for arguments <- [nil, [], %Request{}] do
      assert_raise ArgumentError, "expected tool arguments to be a plain map", fn ->
        call_tool(Server, "add", arguments)
      end
    end
  end
end
