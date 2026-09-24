defmodule PorticoExample.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

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
