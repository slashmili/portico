defmodule PorticoExample.MCPTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "adds integers", %{mcp: mcp} do
    result = call_tool mcp, "add", %{"a" => 2, "b" => 3}
    assert_text result, "5"
  end

  test "adds negative integers and zero", %{mcp: mcp} do
    for {a, b, expected} <- [{-4, 2, "-2"}, {0, 0, "0"}] do
      result = call_tool mcp, "add", %{"a" => a, "b" => b}
      assert_text result, expected
    end
  end

  test "invalid inputs return an actionable tool error", %{mcp: mcp} do
    for arguments <- [%{}, %{"a" => "2", "b" => 3}, %{"a" => 2, "b" => 3, "extra" => true}] do
      result = call_tool mcp, "add", arguments
      assert result.is_error
      assert_text result, "Provide exactly two integers, a and b."
      assert_text result, "Example: a=2, b=3."
    end
  end
end
