defmodule Portico.Protocol.OutputSchemaTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  alias Portico.{Result, Test}

  defmodule Tool do
    use Portico.Tool,
      input_schema: %{type: "object"},
      output_schema: %{
        type: "object",
        properties: %{count: %{"$ref" => "#/$defs/count"}},
        "$defs": %{count: %{type: "integer", minimum: 0}},
        required: ["count"],
        additionalProperties: false
      }

    def call(%{"stream" => true} = args, _), do: {:noreply, args, :stream}

    def call(%{"form" => true}, _) do
      {:ok, form} =
        Portico.Input.form("Count?",
          schema: %{
            type: "object",
            properties: %{count: %{type: "integer"}},
            required: ["count"]
          }
        )

      {:ok, form, "count"}
    end

    def call(%{"missing" => true}, _), do: Result.text("missing")
    def call(%{"error" => true}, _), do: Result.error("Expected failure")
    def call(%{"forged" => true}, _), do: {:ok, %Result{structured_content: %{count: 2}}}
    def call(%{"value" => value}, _), do: Result.structured(value)
    def handle_stream(args, _), do: call(Map.delete(args, "stream"), nil)

    def handle_input({:accept, content}, "count", request) do
      if request.arguments["stream"],
        do: {:noreply, %{"value" => content}, :stream},
        else: Result.structured(content)
    end

    def handle_input(:decline, "count", _), do: Result.error("Declined")
  end

  defmodule Server do
    use Portico.Server, name: "output", version: "1"
    tool "data", Tool
  end

  test "lists normalized schema without exposing the validator" do
    [tool] = Portico.Server.tools(Server)
    assert tool.output_schema["required"] == ["count"]
    refute Map.has_key?(tool, :output_validator)
    {:reply, reply} = Portico.Protocol.Dispatcher.dispatch(Server, message("tools/list", %{}))
    assert [listed] = reply["result"]["tools"]
    assert listed["outputSchema"] == tool.output_schema
  end

  test "validates successful immediate and streamed results and permits expected errors" do
    for stream <- [false, true] do
      for args <- [%{"value" => %{"count" => 2}}, %{"forged" => true}, %{"error" => true}] do
        args = Map.put(args, "stream", stream)
        assert {:ok, _} = Test.call_tool(Server, "data", args)
        {status, reply} = invoke(args)
        assert status == 200
        assert reply["result"]["resultType"] == "complete"
      end

      for args <- [
            %{"missing" => true},
            %{"value" => nil},
            %{"value" => %{"count" => -1}},
            %{"value" => %{"count" => "secret"}},
            %{"value" => %{}}
          ] do
        args = Map.put(args, "stream", stream)
        assert Test.call_tool(Server, "data", args) == {:error, :invalid_output}
        {status, reply} = invoke(args)
        assert status == if(stream, do: 200, else: 500)
        assert reply["error"] == %{"code" => -32603, "message" => "Internal error"}
        refute inspect(reply) =~ "secret"
      end
    end
  end

  test "checks final form continuations without requiring output on input-required results" do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("o", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    context = %Portico.Test.Context{
      server: Server,
      client_capabilities: %{"elicitation" => %{"form" => %{}}}
    }

    for stream <- [false, true] do
      args = %{"form" => true, "stream" => stream}
      assert {:ok, %Portico.Input{}, token} = Test.call_tool(context, "data", args)

      for count <- [2, -1] do
        outcome =
          Test.call_tool(context, "data", args,
            request_state: token,
            input_responses: %{
              "form" => %{"action" => "accept", "content" => %{"count" => count}}
            }
          )

        if count == 2,
          do: assert({:ok, %Result{structured_content: %{"count" => 2}}} = outcome),
          else: assert(outcome == {:error, :invalid_output})
      end

      assert {:ok, %Result{is_error: true}} =
               Test.call_tool(context, "data", args,
                 request_state: token,
                 input_responses: %{"form" => %{"action" => "decline"}}
               )
    end
  end

  defp message(method, params) do
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

  defp invoke(args) do
    conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!(message("tools/call", %{"name" => "data", "arguments" => args}))
      )
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
