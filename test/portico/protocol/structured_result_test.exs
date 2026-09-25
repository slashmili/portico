defmodule Portico.Protocol.StructuredResultTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  alias Portico.{Result, Test}
  alias Portico.Protocol.Encoder

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}
    def call(%{"stream" => true} = args, _), do: {:noreply, args, :stream}
    def call(%{"invalid" => true}, _), do: {:ok, %Result{structured_content: self()}}
    def call(%{"value" => value}, _), do: Result.structured(value)
    def handle_stream(args, _), do: call(Map.delete(args, "stream"), nil)
  end

  defmodule Server do
    use Portico.Server, name: "structured", version: "1"
    tool "data", Tool
  end

  test "encoding distinguishes omitted structured content from explicit null and rejects forged data" do
    assert {:ok, plain} = Encoder.tool_result(%Result{})
    refute Map.has_key?(plain, "structuredContent")
    assert {:ok, explicit} = Encoder.tool_result(%Result{structured_content: nil})
    assert Map.has_key?(explicit, "structuredContent")
    assert explicit["structuredContent"] == nil
    assert Encoder.tool_result(%Result{structured_content: self()}) == {:error, :invalid_result}
  end

  test "HTTP, SSE and the test helper preserve structured values and reject malformed results" do
    for stream <- [false, true], value <- [%{"sum" => 5}, [1, true], "hello", 5, false, nil] do
      args = %{"stream" => stream, "value" => value}
      assert {:ok, result} = Test.call_tool(Server, "data", args)
      assert result.structured_content == value
      {status, response} = invoke(args)
      assert status == 200
      assert response["result"]["resultType"] == "complete"
      assert Map.has_key?(response["result"], "structuredContent")
      assert response["result"]["structuredContent"] == value
      assert [%{"type" => "text", "text" => json}] = response["result"]["content"]
      assert JSON.decode!(json) == value
    end

    for stream <- [false, true] do
      args = %{"stream" => stream, "invalid" => true}
      assert Test.call_tool(Server, "data", args) == {:error, :invalid_result}
      {status, response} = invoke(args)
      assert status == if(stream, do: 200, else: 500)
      assert response["error"] == %{"code" => -32603, "message" => "Internal error"}
    end
  end

  defp invoke(args) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "data",
        "arguments" => args,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      conn(:post, "/mcp", JSON.encode!(message))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "data")
      |> Portico.Plug.call(Portico.Plug.init(server: Server))

    body =
      if args["stream"],
        do: conn.resp_body |> String.split("data: ") |> List.last() |> String.trim(),
        else: conn.resp_body

    {conn.status, JSON.decode!(body)}
  end
end
