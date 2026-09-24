defmodule PorticoExample.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import ExUnit.CaptureLog

  test "logs decoded MCP parameters while still dispatching the posted body" do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "add",
        "arguments" => %{"a" => 2, "b" => 3},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    log =
      capture_log(fn ->
        conn =
          conn(:post, "/mcp", JSON.encode!(message))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
          |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
          |> Plug.Conn.put_req_header("mcp-method", "tools/call")
          |> Plug.Conn.put_req_header("mcp-name", "add")
          |> PorticoExample.Router.call(PorticoExample.Router.init([]))

        assert conn.status == 200

        assert JSON.decode!(conn.resp_body)["result"]["content"] ==
                 [%{"type" => "text", "text" => "5"}]
      end)

    assert log =~ ~s|Processing MCP "tools/call" (id=7)|
    assert log =~ "Parameters:"
    assert log =~ ~s("arguments" => %{"a" => 2, "b" => 3})
  end

  test "mounts MCP at the documented path" do
    conn = conn(:get, "/mcp") |> PorticoExample.Router.call(PorticoExample.Router.init([]))
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
  end

  test "returns 404 outside the MCP endpoint" do
    conn = conn(:get, "/missing") |> PorticoExample.Router.call(PorticoExample.Router.init([]))
    assert conn.status == 404
  end
end
