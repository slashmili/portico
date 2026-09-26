defmodule PorticoExample.ResourceTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "looks up policies and reports missing entries", %{mcp: mcp} do
    {:ok, content} = read_resource mcp, "company://policies/leave"
    assert content.text == "Request leave through your manager."
    assert {:error, :resource_not_found} = read_resource(mcp, "company://policies/missing")
  end

  test "reads multiple documents", %{mcp: mcp} do
    {:ok, [readme, guide]} = read_resource mcp, "company://docs"

    assert {readme.uri, readme.text, readme.mime_type} ==
             {"company://docs/readme", "Welcome", "text/plain"}

    assert {guide.uri, guide.text, guide.mime_type} ==
             {"company://docs/guide", "# Getting started", "text/markdown"}
  end

  test "reads raw bytes", %{mcp: mcp} do
    {:ok, content} = read_resource mcp, "company://sample"
    assert content.blob == <<0, 1, 2, 255>>
    assert content.text == nil
    assert content.uri == "company://sample"
    assert content.mime_type == "application/octet-stream"
  end

  test "reads a template with decoded variables", %{mcp: mcp} do
    {:ok, content} = read_resource(mcp, "company://handbook/caf%C3%A9")
    assert content.uri == "company://handbook/caf%C3%A9"
    assert content.text == "Handbook section: café"
    assert content.mime_type == "text/plain"
  end

  test "reads the declared handbook", %{mcp: mcp} do
    {:ok, content} = read_resource(mcp, "company://handbook")
    assert content.uri == "company://handbook"
    assert content.mime_type == "text/plain"
    assert content.text == "Welcome to the company. Ask questions and share what you learn."
    assert {:error, :resource_not_found} = read_resource(mcp, "company://missing")
  end
end
