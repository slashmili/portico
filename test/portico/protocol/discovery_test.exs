defmodule Portico.Protocol.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Dispatcher

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(_, _), do: raise("discovery must not invoke tools")
  end

  defmodule Server do
    use Portico.Server, name: "discovery-test", version: "dev"
    tool "example", Tool
  end

  defmodule OtherServer do
    use Portico.Server, name: "other", version: "2"
  end

  defp request(version \\ "2026-07-28") do
    %{
      "jsonrpc" => "2.0",
      "id" => "discover-1",
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  test "discovers server identity without advertising unfinished capabilities" do
    assert Dispatcher.dispatch(Server, request()) ==
             {:reply,
              %{
                "jsonrpc" => "2.0",
                "id" => "discover-1",
                "result" => %{
                  "resultType" => "complete",
                  "supportedVersions" => ["2026-07-28"],
                  "capabilities" => %{"tools" => %{}},
                  "_meta" => %{
                    "io.modelcontextprotocol/serverInfo" => %{
                      "name" => "discovery-test",
                      "version" => "dev"
                    }
                  }
                }
              }}
  end

  test "uses the selected server and preserves numeric IDs through JSON encoding" do
    assert {:reply, response} = Dispatcher.dispatch(OtherServer, %{request() | "id" => 0})
    assert response["id"] === 0

    assert response["result"]["_meta"]["io.modelcontextprotocol/serverInfo"] ==
             %{"name" => "other", "version" => "2"}

    assert JSON.decode!(JSON.encode!(response)) == response
  end

  test "unsupported versions fail before method lookup, including discovery" do
    for version <- ["2025-11-25", "2099-01-01"],
        method <- ["server/discover", "unknown/method"] do
      message = %{request(version) | "method" => method}

      assert Dispatcher.dispatch(Server, message) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "id" => "discover-1",
                  "error" => %{
                    "code" => -32022,
                    "message" => "Unsupported protocol version",
                    "data" => %{"requested" => version, "supported" => ["2026-07-28"]}
                  }
                }}
    end
  end

  test "checks the version independently on every request" do
    assert {:reply, %{"result" => _}} = Dispatcher.dispatch(Server, request())

    assert {:reply, %{"error" => %{"code" => -32022}}} =
             Dispatcher.dispatch(Server, request("2025-11-25"))

    assert {:reply, %{"result" => _}} = Dispatcher.dispatch(Server, request())
  end

  test "malformed metadata fails before version support checks" do
    message =
      put_in(
        request("2099-01-01"),
        ["params", "_meta", "io.modelcontextprotocol/clientCapabilities"],
        nil
      )

    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, message)
  end

  test "discovery notifications produce no response regardless of version" do
    for version <- ["2026-07-28", "2099-01-01"] do
      assert Dispatcher.dispatch(Server, Map.delete(request(version), "id")) == :no_response
    end
  end
end
