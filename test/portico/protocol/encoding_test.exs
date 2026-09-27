defmodule Portico.Protocol.EncodingTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  alias Portico.Protocol.Encoder

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(%{"stream" => true}, _), do: {:noreply, nil, :stream}
    def call(_, _), do: Portico.Result.text("done")
    @impl true
    def handle_stream(_, _), do: Portico.Result.text("done")
  end

  defmodule Server do
    use Portico.Server, name: "encoding", version: "1"
    tool "work", Tool
  end

  # Simulate malformed runtime metadata reaching the transport after dispatch.
  defmodule InvalidMetadata do
    def __portico__(:info), do: %{name: <<255>>, version: "encoding-private-metadata"}
    def __portico__(:tools), do: Server.__portico__(:tools)
  end

  test "JSON encoding rejects unsupported values and invalid UTF-8 with a stable reason" do
    for value <- [self(), fn -> :ok end, <<255>>, %{"secret" => <<255>>}] do
      assert Encoder.json(value) == {:error, :invalid_json}
    end

    assert Encoder.json(%{"text" => "日本語"}) == {:ok, ~s({"text":"日本語"})}
  end

  test "internal error fallback keeps valid IDs and omits invalid IDs" do
    assert Encoder.internal_error("id")["id"] == "id"

    for id <- [nil, <<255>>, true, %{}] do
      refute Map.has_key?(Encoder.internal_error(id), "id")
    end
  end

  test "HTTP and SSE encoding failures produce sanitized final errors" do
    for streaming <- [false, true] do
      message = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{
          "name" => "work",
          "arguments" => %{"stream" => streaming},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn(:post, "/mcp", JSON.encode!(message))
            |> put_req_header("content-type", "application/json")
            |> put_req_header("accept", "application/json, text/event-stream")
            |> put_req_header("mcp-protocol-version", "2026-07-28")
            |> put_req_header("mcp-method", "tools/call")
            |> put_req_header("mcp-name", "work")
            |> Portico.Plug.call(Portico.Plug.init(server: InvalidMetadata))

          assert conn.halted
          assert conn.status == if(streaming, do: 200, else: 500)

          body =
            if streaming do
              [_, data] = String.split(conn.resp_body, "data: ")
              String.trim(data)
            else
              conn.resp_body
            end

          assert JSON.decode!(body) == %{
                   "jsonrpc" => "2.0",
                   "id" => 7,
                   "error" => %{"code" => -32603, "message" => "Internal error"}
                 }

          refute conn.resp_body =~ "encoding-private-metadata"
        end)

      assert log =~ "encoding failed: :invalid_json"
      refute log =~ "encoding-private-metadata"
    end
  end
end
