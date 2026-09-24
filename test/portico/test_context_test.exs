defmodule Portico.TestContextTest do
  defmodule Echo do
    use Portico.Tool, input_schema: %{type: "object"}

    @impl true
    def call(%{"text" => text}, request) do
      send(request.assigns.observer, {:context, request.assigns})
      {:reply, Portico.Result.text(text), Portico.Request.assign(request, :changed, true)}
    end
  end

  defmodule Server do
    use Portico.Server, name: "context-test", version: "1"
    tool "echo", Echo
  end

  use Portico.Test, server: Server, async: true

  setup %{mcp: mcp} do
    assert mcp.server == Server
    assert mcp.assigns == %{}
    %{mcp: %{mcp | assigns: %{observer: self(), locale: "en"}}}
  end

  test "invokes the configured server with setup assigns", %{mcp: mcp} do
    result = call_tool mcp, "echo", %{"text" => "hello"}
    assert_text result, "hello"
    assert_received {:context, %{observer: observer, locale: "en"}}
    assert observer == self()
  end

  test "per-call assigns override defaults without leaking into later calls", %{mcp: mcp} do
    call_tool mcp, "echo", %{"text" => "one"}, assigns: %{locale: "de"}
    assert_received {:context, %{locale: "de"} = first}
    refute Map.has_key?(first, :changed)

    call_tool mcp, "echo", %{"text" => "two"}
    assert_received {:context, %{locale: "en"} = second}
    refute Map.has_key?(second, :changed)
    assert mcp.assigns == %{observer: self(), locale: "en"}
  end

  test "context calls still check the configured server's routes", %{mcp: mcp} do
    assert_raise ArgumentError, ~r/unknown tool "missing"/, fn ->
      call_tool mcp, "missing", %{}
    end
  end

  test "invalid context assigns are rejected", %{mcp: mcp} do
    assert_raise ArgumentError, ~r/plain map with atom keys/, fn ->
      call_tool %{mcp | assigns: %{"locale" => "en"}}, "echo", %{"text" => "hello"}
    end
  end

  test "assert_text finds an exact text item and returns the result" do
    result = %Portico.Result{
      content: [%{type: "text", text: "first"}, %{type: "text", text: "second"}]
    }

    assert assert_text(result, "second") == result

    assert_raise ExUnit.AssertionError, fn ->
      assert_text result, "sec"
    end
  end

  test "assert_text rejects a non-result and non-text content" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_text %{content: []}, "hello"
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert_text %Portico.Result{content: [%{type: "image", text: "hello"}]}, "hello"
    end
  end

  test "assert_text evaluates its arguments once" do
    result = fn ->
      send(self(), :evaluated_result)
      Portico.Result.text("hello")
    end

    expected = fn ->
      send(self(), :evaluated_expected)
      "hello"
    end

    assert_text result.(), expected.()
    assert_received :evaluated_result
    assert_received :evaluated_expected
    refute_received :evaluated_result
    refute_received :evaluated_expected
  end
end

defmodule Portico.TestDefaultsTest do
  defmodule Add do
    use Portico.Tool, input_schema: %{type: "object"}

    @impl true
    def call(%{"a" => a, "b" => b}, request) do
      {:reply, Portico.Result.text("#{a + b}"), request}
    end
  end

  defmodule Server do
    use Portico.Server, name: "default-context", version: "1"
    tool "add", Add
  end

  use Portico.Test, server: Server, async: true

  test "provides a ready-to-use context without a setup block", %{mcp: mcp} do
    result = call_tool mcp, "add", %{"a" => 2, "b" => 3}
    assert_text result, "5"
    assert mcp == %Portico.Test.Context{server: Server, assigns: %{}}
  end
end
