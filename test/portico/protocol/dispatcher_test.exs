defmodule Portico.Protocol.DispatcherTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Dispatcher

  defmodule GuardedTool do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(_, _), do: raise("protocol validation must not invoke this tool")
  end

  defmodule Server do
    use Portico.Server, name: "dispatcher-test", version: "1"
    tool "guarded", GuardedTool
  end

  @request %{
    "jsonrpc" => "2.0",
    "id" => "request-1",
    "method" => "tools/call",
    "params" => %{
      "name" => "guarded",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }
  }

  test "malformed envelopes preserve a readable ID in the error" do
    for id <- [0, -1, "", "request-1"] do
      message = @request |> Map.put("id", id) |> Map.put("method", nil)

      assert Dispatcher.dispatch(Server, message) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "error" => %{"code" => -32600, "message" => "Invalid request"}
                }}
    end
  end

  test "malformed or unreadable IDs are omitted from errors" do
    for message <- [
          nil,
          [],
          %{},
          %{@request | "id" => nil},
          %{@request | "id" => true},
          %{@request | "id" => 1.0},
          %{@request | "id" => <<255>>}
        ] do
      assert Dispatcher.dispatch(Server, message) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "error" => %{"code" => -32600, "message" => "Invalid request"}
                }}
    end
  end

  test "missing or malformed metadata fails before method handling" do
    for params <- [%{}, %{"name" => "guarded"}, %{"_meta" => nil}] do
      assert Dispatcher.dispatch(Server, %{@request | "params" => params}) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "id" => "request-1",
                  "error" => %{"code" => -32602, "message" => "Invalid params"}
                }}
    end

    assert {:reply, %{"error" => %{"code" => -32602}}} =
             Dispatcher.dispatch(Server, Map.delete(@request, "params"))
  end

  test "malformed elicitation capabilities are rejected before a tool callback" do
    message =
      put_in(@request, ["params", "_meta", "io.modelcontextprotocol/clientCapabilities"], %{
        "elicitation" => %{"form" => true}
      })

    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, message)

    context = %Portico.Test.Context{
      server: Server,
      client_capabilities: %{"elicitation" => %{"url" => nil}}
    }

    assert Portico.Test.call_tool(context, "guarded", %{}) == {:error, :invalid_params}
  end

  test "invalid optional client info fails before callbacks in protocol and test helpers" do
    info = %{
      "name" => "client",
      "version" => "1",
      "icons" => [%{"src" => "x", "theme" => "auto"}]
    }

    message = put_in(@request, ["params", "_meta", "io.modelcontextprotocol/clientInfo"], info)
    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, message)
    context = %Portico.Test.Context{server: Server, client_info: info}
    assert Portico.Test.call_tool(context, "guarded", %{}) == {:error, :invalid_params}
  end

  test "invalid request log level fails before tool execution" do
    message = put_in(@request, ["params", "_meta", "io.modelcontextprotocol/logLevel"], "verbose")
    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, message)
    assert Dispatcher.call_tool_request(Server, message, %{}) == {:error, :invalid_params}
  end

  test "invalid metadata keys fail before tool execution" do
    message = put_in(@request, ["params", "_meta", "bad key"], true)
    assert {:reply, %{"error" => %{"code" => -32602}}} = Dispatcher.dispatch(Server, message)
    assert Dispatcher.call_tool_request(Server, message, %{}) == {:error, :invalid_params}
  end

  test "unimplemented protocol methods return method not found" do
    for method <- ["unknown/method", "guarded"] do
      assert Dispatcher.dispatch(Server, %{@request | "method" => method}) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "id" => "request-1",
                  "error" => %{"code" => -32601, "message" => "Method not found"}
                }}
    end
  end

  test "notifications produce no reply and do not invoke request methods" do
    notification = Map.delete(@request, "id")

    assert Dispatcher.dispatch(Server, notification) == :no_response
    assert Dispatcher.dispatch(Server, Map.delete(notification, "params")) == :no_response

    assert Dispatcher.dispatch(Server, %{notification | "params" => %{"_meta" => nil}}) ==
             :no_response
  end

  test "a malformed envelope without an ID is not treated as a valid notification" do
    message = @request |> Map.delete("id") |> Map.put("jsonrpc", "1.0")
    assert {:reply, %{"error" => %{"code" => -32600}}} = Dispatcher.dispatch(Server, message)
  end
end
