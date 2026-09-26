defmodule Portico.ResourceTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Portico.{Resource, Server, Test}
  alias Portico.Protocol.Dispatcher

  defmodule Handbook do
    use Portico.Resource,
      name: "handbook",
      description: "Company handbook",
      mime_type: "text/plain"

    def read(request) do
      if pid = request.assigns[:observer], do: send(pid, request)

      case request.assigns[:mode] do
        :error -> {:error, :unavailable}
        :bad -> {:ok, "bad"}
        :forged -> {:ok, %Resource{text: self()}}
        :raise -> raise "application failure"
        _ -> Resource.text(request.assigns[:text] || "Welcome")
      end
    end
  end

  defmodule Catalog do
    use Portico.Server, name: "resources", version: "1"
    resource "company://z", Handbook
    resource "company://handbook", Handbook
  end

  test "declares resources in URI order and returns validated text with fresh context" do
    assert Enum.map(Server.resources(Catalog), & &1.uri) == ["company://handbook", "company://z"]

    assert {:ok, content} =
             Test.read_resource(Catalog, "company://handbook", assigns: %{observer: self()})

    assert content.text == "Welcome"
    assert content.uri == "company://handbook"
    assert content.mime_type == "text/plain"

    assert_received %Portico.Request{
      method: "resources/read",
      resource_uri: "company://handbook",
      server: Catalog
    }

    assert {:ok, %Resource{text: "Welcome"}} = Test.read_resource(Catalog, "company://z")
    refute_received %Portico.Request{}
  end

  test "discovery, resource listing and reading use protocol shapes and private zero-TTL caching" do
    {:reply, discovery} = Dispatcher.dispatch(Catalog, message("server/discover"))
    assert discovery["result"]["capabilities"]["resources"] == %{}
    {:reply, listing} = Dispatcher.dispatch(Catalog, message("resources/list"))

    assert [%{"uri" => "company://handbook", "name" => "handbook", "mimeType" => "text/plain"}, _] =
             listing["result"]["resources"]

    for method <- ["resources/list", "resources/read", "resources/templates/list"] do
      {:reply, reply} =
        Dispatcher.dispatch(Catalog, message(method, %{"uri" => "company://handbook"}))

      assert reply["result"]["cacheScope"] == "private"
      assert reply["result"]["ttlMs"] == 0
      assert reply["result"]["resultType"] == "complete"
    end

    {:reply, read} =
      Dispatcher.dispatch(Catalog, message("resources/read", %{"uri" => "company://handbook"}))

    assert read["result"]["contents"] == [
             %{"uri" => "company://handbook", "mimeType" => "text/plain", "text" => "Welcome"}
           ]
  end

  test "runtime failures return tuples; application crashes surface in tests and are sanitized on the wire" do
    assert Resource.text(nil) == {:error, :invalid_text}
    assert Resource.text(<<255>>) == {:error, :invalid_text}

    for {mode, reason} <- [
          error: :unavailable,
          bad: :invalid_callback_return,
          forged: :invalid_resource
        ] do
      assert Test.read_resource(Catalog, "company://handbook", assigns: %{mode: mode}) ==
               {:error, reason}

      {:reply, reply} =
        Dispatcher.dispatch(
          Catalog,
          message("resources/read", %{"uri" => "company://handbook"}),
          %{mode: mode}
        )

      assert reply["error"] == %{"code" => -32603, "message" => "Internal error"}
    end

    assert_raise RuntimeError, "application failure", fn ->
      Test.read_resource(Catalog, "company://handbook", assigns: %{mode: :raise})
    end

    assert {:reply, %{"error" => %{"code" => -32603}}} =
             Dispatcher.dispatch(
               Catalog,
               message("resources/read", %{"uri" => "company://handbook"}),
               %{mode: :raise}
             )
  end

  test "invalid parameters and missing resources never invoke the callback" do
    for params <- [
          %{},
          %{"uri" => nil},
          %{"uri" => "/relative"},
          %{"uri" => "company://missing"},
          %{"uri" => "company://handbook", "requestState" => "unsupported"}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Catalog, message("resources/read", params), %{observer: self()})
    end

    assert Test.read_resource(Catalog, "company://missing") == {:error, :resource_not_found}
    assert Test.read_resource(nil, "company://handbook") == {:error, :invalid_server}
    assert Test.read_resource(%{}, "company://handbook") == {:error, :invalid_target}

    assert Test.read_resource(Catalog, "company://handbook", timeout: 5) ==
             {:error, :invalid_options}

    assert Test.read_resource(Catalog, "company://handbook", assigns: %{"bad" => true}) ==
             {:error, :invalid_assigns}

    refute_received %Portico.Request{}
  end

  test "HTTP checks the URI header and maps read failures to status codes" do
    for {uri, header, status, code} <- [
          {"company://handbook", "company://handbook", 200, nil},
          {"company://handbook", "company://other", 400, -32020},
          {"company://missing", "company://missing", 400, -32602}
        ] do
      conn =
        Plug.Test.conn(:post, "/mcp", JSON.encode!(message("resources/read", %{"uri" => uri})))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
        |> Plug.Conn.put_req_header("mcp-method", "resources/read")
        |> Plug.Conn.put_req_header("mcp-name", header)
        |> Portico.Plug.call(Portico.Plug.init(server: Catalog))

      assert conn.status == status
      body = JSON.decode!(conn.resp_body)

      if code,
        do: assert(body["error"]["code"] == code),
        else: assert(body["result"]["contents"] != [])
    end
  end

  test "list cursors and invalid helper metadata are rejected" do
    for method <- ["resources/list", "resources/templates/list"] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Catalog, message(method, %{"cursor" => "unsupported"}))
    end

    context = %Portico.Test.Context{server: Catalog, protocol_version: "old"}

    assert {:error, {:unsupported_protocol_version, "old", _}} =
             Test.read_resource(context, "company://handbook")

    assert {:error, :invalid_assigns} =
             Test.read_resource(%{context | assigns: nil}, "company://handbook")
  end

  defp message(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }
  end
end
