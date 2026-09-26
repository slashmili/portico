defmodule PorticoExample.CompletionTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "suggests languages and builds the explanation prompt", %{mcp: mcp} do
    {:ok, result} = complete mcp, {:prompt, "explain_code"}, "language", "e"
    assert result == %{values: ["elixir", "erlang"], total: 2, has_more: false}
    {:ok, empty} = complete mcp, {:prompt, "explain_code"}, "code", ""
    assert empty.values == []
    {:ok, prompt} = get_prompt mcp, "explain_code", %{"language" => "elixir", "code" => "1 + 1"}
    assert hd(prompt.messages).content.text == "Explain this elixir code:\n\n1 + 1"
  end

  test "suggests policy template variables", %{mcp: mcp} do
    {:ok, result} = complete mcp, {:resource, "company://policies/{name}"}, "name", "le"
    assert result.values == ["leave"]
    {:ok, result} = complete mcp, {:resource, "company://policies/{name}"}, "name", "unknown"
    assert result.values == []
  end
end
