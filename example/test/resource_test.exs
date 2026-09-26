defmodule PorticoExample.ResourceTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "reads the declared handbook", %{mcp: mcp} do
    {:ok, content} = read_resource(mcp, "company://handbook")
    assert content.uri == "company://handbook"
    assert content.mime_type == "text/plain"
    assert content.text == "Welcome to the company. Ask questions and share what you learn."
    assert {:error, :resource_not_found} = read_resource(mcp, "company://missing")
  end
end
