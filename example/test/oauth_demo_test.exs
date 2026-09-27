defmodule PorticoExample.OAuthDemoTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  test "the protected route challenges while metadata stays public" do
    route = &PorticoExample.Router.call(&1, PorticoExample.Router.init([]))
    assert route.(conn(:post, "/protected/mcp")).status == 401
    metadata = route.(conn(:get, "/.well-known/oauth-protected-resource/protected/mcp"))
    assert metadata.status == 200
    assert JSON.decode!(metadata.resp_body)["resource"] =~ "/protected/mcp"
  end

  test "a verified user reaches the tool through assigns" do
    message = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{
        name: "whoami",
        arguments: %{},
        _meta: %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      conn(:post, "/protected/mcp", JSON.encode!(message))
      |> put_req_header("authorization", "Bearer alice-demo-token")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "whoami")
      |> PorticoExample.Router.call(PorticoExample.Router.init([]))

    assert conn.status == 200

    assert JSON.decode!(conn.resp_body)["result"]["content"] == [
             %{"type" => "text", "text" => "Authenticated as alice"}
           ]
  end

  test "the example verifier checks audience, expiry, token lookup and scope" do
    context = Map.take(PorticoExample.OAuthDemo.options(), [:resource, :scopes])

    assert {:ok, %{current_user: %{id: "alice"}}} =
             PorticoExample.OAuthDemo.verify_token("alice-demo-token", context)

    assert {:error, :invalid_token} = PorticoExample.OAuthDemo.verify_token("unknown", context)

    assert {:error, :invalid_token} =
             PorticoExample.OAuthDemo.verify_token("alice-demo-token", %{
               context
               | resource: "https://other.example"
             })

    assert {:error, :insufficient_scope} =
             PorticoExample.OAuthDemo.verify_token("limited-demo-token", context)

    expiry = Application.fetch_env!(:portico_example, :oauth_demo_expires_at)
    on_exit(fn -> Application.put_env(:portico_example, :oauth_demo_expires_at, expiry) end)
    Application.put_env(:portico_example, :oauth_demo_expires_at, 0)

    assert {:error, :invalid_token} =
             PorticoExample.OAuthDemo.verify_token("alice-demo-token", context)
  end
end
