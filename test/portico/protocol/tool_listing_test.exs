defmodule Portico.Protocol.ToolListingTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Dispatcher

  defmodule Described do
    use Portico.Tool,
      description: "Describe a value",
      input_schema: %{type: "object", properties: %{value: %{type: "string"}}}

    @impl true
    def call(_, _), do: raise("listing must not invoke a tool")
  end

  defmodule Bare do
    use Portico.Tool, input_schema: %{"type" => "object", "additionalProperties" => false}
    @impl true
    def call(_, _), do: raise("listing must not invoke a tool")
  end

  defmodule Server do
    use Portico.Server, name: "listing-test", version: "1"
    tool "zebra", Bare
    tool "alpha", Described
  end

  defmodule Empty do
    use Portico.Server, name: "empty", version: "1"
  end

  defp request do
    %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  test "lists the complete catalog in name order without implementation details" do
    assert {:reply, response} = Dispatcher.dispatch(Server, request())

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => 0,
             "result" => %{
               "resultType" => "complete",
               "cacheScope" => "private",
               "ttlMs" => 0,
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "listing-test",
                   "version" => "1"
                 }
               },
               "tools" => [
                 %{
                   "name" => "alpha",
                   "description" => "Describe a value",
                   "inputSchema" => %{
                     "type" => "object",
                     "properties" => %{"value" => %{"type" => "string"}}
                   }
                 },
                 %{
                   "name" => "zebra",
                   "inputSchema" => %{
                     "type" => "object",
                     "additionalProperties" => false
                   }
                 }
               ]
             }
           }

    assert Dispatcher.dispatch(Server, request()) == {:reply, response}
  end

  test "normalized schemas are identical in the catalog and JSON listing" do
    assert {:reply, response} = Dispatcher.dispatch(Server, request())
    decoded = response |> JSON.encode!() |> JSON.decode!()

    assert hd(decoded["result"]["tools"])["inputSchema"] == %{
             "type" => "object",
             "properties" => %{"value" => %{"type" => "string"}}
           }

    assert [%{input_schema: %{"type" => "object"}}, _] = Portico.Server.tools(Server)
  end

  test "an independent server with no tools returns an empty list" do
    assert {:reply, %{"result" => result}} = Dispatcher.dispatch(Empty, request())
    assert result["tools"] == []
    assert result["cacheScope"] == "private"
    assert result["ttlMs"] == 0
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "empty"
    refute Map.has_key?(result, "nextCursor")
  end

  test "rejects all supplied cursors since this implementation issues none" do
    for cursor <- ["unknown", "", nil, 42, %{}, []] do
      message = put_in(request(), ["params", "cursor"], cursor)

      assert {:reply, %{"id" => 0, "error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Server, message)
    end
  end

  test "listing passes through required metadata and version checks" do
    missing = put_in(request(), ["params", "_meta"], %{})
    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, missing)

    unsupported =
      put_in(
        request(),
        ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
        "2025-11-25"
      )

    assert {:reply, %{"error" => %{"code" => -32022}}} = Dispatcher.dispatch(Server, unsupported)
  end

  test "listing notifications produce no response" do
    assert Dispatcher.dispatch(Server, Map.delete(request(), "id")) == :no_response
  end
end
