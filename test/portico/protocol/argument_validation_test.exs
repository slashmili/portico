defmodule Portico.Protocol.ArgumentValidationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Portico.Test
  import Plug.Conn
  import Plug.Test
  alias Portico.Protocol.Dispatcher
  alias Portico.Result

  defmodule Checked do
    use Portico.Tool,
      input_schema: %{
        type: "object",
        properties: %{
          count: %{"$ref" => "#/$defs/count"},
          tags: %{type: "array", items: %{type: "string", minLength: 1}},
          label: %{type: "string", default: "default-label"}
        },
        "$defs": %{count: %{type: "integer", minimum: 1}},
        required: ["count"],
        additionalProperties: false
      }

    @impl true
    def call(arguments, request) do
      send(request.assigns.observer, {:invoked, arguments})
      Result.text("called")
    end
  end

  defmodule Server do
    use Portico.Server, name: "validation", version: "1"
    tool "checked", Checked
  end

  @invalid [
    %{},
    %{"count" => "private-value"},
    %{"count" => true},
    %{"count" => nil},
    %{"count" => 1.5},
    %{"count" => 0},
    %{"count" => 1, "extra" => "private-value"},
    %{"count" => 1, "tags" => [""]},
    %{"count" => 1, "tags" => [42]}
  ]
  @failure "Tool arguments do not match the input schema."

  defp message(arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "checked",
        "arguments" => arguments,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  test "test helpers return a tool error and never invoke callbacks for invalid inputs" do
    for arguments <- @invalid do
      {:ok, result} = call_tool Server, "checked", arguments, assigns: %{observer: self()}
      assert result.is_error
      assert [%{type: "text", text: text}] = result.content
      assert String.starts_with?(text, @failure)
      refute_received {:invoked, _}
    end
  end

  test "protocol dispatch returns the same completed error with no submitted values" do
    for arguments <- @invalid do
      assert {:reply, response} =
               Dispatcher.dispatch(Server, message(arguments), %{observer: self()})

      refute Map.has_key?(response, "error")
      assert response["id"] == 7
      assert response["result"]["resultType"] == "complete"
      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert String.starts_with?(text, @failure)
      refute JSON.encode!(response) =~ "private-value"
      refute_received {:invoked, _}
    end
  end

  test "valid input reaches callbacks unchanged without defaults or integer coercion" do
    for arguments <- [%{"count" => 2}, %{"count" => 2.0, "tags" => ["ok"]}] do
      {:ok, result} = call_tool Server, "checked", arguments, assigns: %{observer: self()}
      assert {:ok, result} == Result.text("called")
      assert_received {:invoked, received}
      assert received === arguments
      refute Map.has_key?(received, "label")
    end
  end

  test "omitted arguments are validated as the default empty object" do
    request = update_in(message(%{}), ["params"], &Map.delete(&1, "arguments"))

    assert {:reply, %{"result" => %{"isError" => true}}} =
             Dispatcher.dispatch(Server, request, %{observer: self()})

    refute_received {:invoked, _}
  end

  test "schema failures use HTTP 200 for raw and already parsed requests" do
    for parsed? <- [false, true] do
      conn =
        conn(:post, "/mcp", JSON.encode!(message(%{"count" => "private-value"})))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-method", "tools/call")
        |> put_req_header("mcp-name", "checked")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> assign(:observer, self())

      conn =
        if parsed?,
          do: Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: JSON)),
          else: conn

      conn = Portico.Plug.call(conn, Portico.Plug.init(server: Server, assigns: [:observer]))
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"]["isError"]
      refute conn.resp_body =~ "private-value"
      refute_received {:invoked, _}
    end
  end

  test "malformed argument containers and unknown tools remain protocol errors" do
    for request <- [message([]), put_in(message(%{}), ["params", "name"], "missing")] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Server, request, %{observer: self()})

      refute_received {:invoked, _}
    end
  end
end
