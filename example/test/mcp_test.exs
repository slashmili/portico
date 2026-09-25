defmodule PorticoExample.MCPTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "adds integers", %{mcp: mcp} do
    result = call_tool mcp, "add", %{"a" => 2, "b" => 3}
    assert_text result, "5"
  end

  test "adds negative integers and zero", %{mcp: mcp} do
    for {a, b, expected} <- [{-4, 2, "-2"}, {0, 0, "0"}, {2.0, 3.0, "5"}] do
      result = call_tool mcp, "add", %{"a" => a, "b" => b}
      assert_text result, expected
    end
  end

  test "invalid inputs return a schema validation tool error", %{mcp: mcp} do
    for {arguments, detail} <- [
          {%{}, ~s("/a": is required; "/b": is required)},
          {%{"a" => "2", "b" => 3}, ~s("/a": expected integer)},
          {%{"a" => 2, "b" => 3, "extra" => true}, ~s("/extra": is not allowed)}
        ] do
      result = call_tool mcp, "add", arguments
      assert result.is_error
      assert_text result, "Tool arguments do not match the input schema. " <> detail
    end
  end

  test "count chooses a normal reply or streams progress", %{mcp: mcp} do
    assert_text call_tool(mcp, "count", %{"to" => 1}), "1"
    owner = self()

    result =
      call_tool mcp, "count", %{"to" => 3},
        on_progress: fn progress -> send(owner, {:progress, progress}) end

    assert_text result, "3"
    for n <- 1..3, do: assert_received({:progress, %{progress: ^n, total: 3}})
  end
end
