defmodule Portico.URLElicitationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  alias Portico.{Input, Result, Test}

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}, elicitation_verifier: &__MODULE__.verify/2
    def call(%{"stream" => true}, _), do: {:noreply, nil, :stream}

    def call(_, _) do
      {:ok, input} = Input.url("Connect", url: "https://example.invalid/connect")
      {:ok, input, "flow"}
    end

    def handle_stream(_, _), do: call(%{}, nil)

    def verify(token, request) do
      if pid = request.assigns[:observer], do: send(pid, :verified)
      Portico.Elicitation.verify(token, request)
    end

    def handle_input(action, "flow", request) do
      if pid = request.assigns[:observer], do: send(pid, {:handled, action})

      case action do
        :accept ->
          if request.assigns[:complete], do: Result.text("Connected"), else: call(%{}, request)

        :decline ->
          Result.error("Declined")

        :cancel ->
          Result.text("Cancelled")
      end
    end
  end

  defmodule Server do
    use Portico.Server, name: "url", version: "1"
    tool "connect", Tool
    tool "other", Tool
  end

  setup do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("u", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    %{
      mcp: %Portico.Test.Context{
        server: Server,
        client_capabilities: %{"elicitation" => %{"url" => %{}}},
        assigns: %{observer: self()}
      }
    }
  end

  test "URL input uses signed state in immediate and streamed responses", %{mcp: mcp} do
    for stream <- [false, true] do
      args = %{"stream" => stream}
      assert {:ok, %Input{mode: :url}, state} = Test.call_tool(mcp, "connect", args)

      assert {:ok, "flow"} =
               Portico.Elicitation.verify(state, %Portico.Request{
                 server: Server,
                 tool_name: "connect",
                 arguments: args
               })

      {200, body} = http(args)
      assert body["result"]["resultType"] == "input_required"

      assert body["result"]["inputRequests"] == %{
               "url" => %{
                 "method" => "elicitation/create",
                 "params" => %{
                   "mode" => "url",
                   "message" => "Connect",
                   "url" => "https://example.invalid/connect"
                 }
               }
             }

      for {action, text} <- [{"decline", "Declined"}, {"cancel", "Cancelled"}] do
        assert {:ok, result} = resume(mcp, args, state, %{"action" => action})
        assert [%{text: ^text}] = result.content
      end

      assert {:ok, %Input{mode: :url}, _} = resume(mcp, args, state, %{"action" => "accept"})
      assert_received {:handled, :accept}

      assert {:ok, %Result{content: [%{text: "Connected"}]}} =
               resume(%{mcp | assigns: %{complete: true}}, args, state, %{"action" => "accept"})

      assert {:ok, %Input{mode: :url}, _} =
               Test.call_tool(mcp, "connect", args, request_state: state)
    end
  end

  test "URL capability is required on initial calls and retries", %{mcp: mcp} do
    for stream <- [false, true] do
      args = %{"stream" => stream}
      {:ok, _, state} = Test.call_tool(mcp, "connect", args)

      for caps <- [%{}, %{"elicitation" => %{}}, %{"elicitation" => %{"form" => %{}}}] do
        context = %{mcp | client_capabilities: caps}
        assert Test.call_tool(context, "connect", args) == {:error, :url_not_supported}

        assert resume(context, args, state, %{"action" => "accept"}) ==
                 {:error, :url_not_supported}

        {status, body} = http(args, %{}, caps)
        assert status == if(stream, do: 200, else: 400)

        assert body["error"] == %{
                 "code" => -32021,
                 "message" => "Missing required client capability",
                 "data" => %{"requiredCapabilities" => %{"elicitation" => %{"url" => %{}}}}
               }

        {400, retry} =
          http(
            args,
            %{"requestState" => state, "inputResponses" => %{"url" => %{"action" => "accept"}}},
            caps
          )

        assert retry["error"] == body["error"]
      end
    end

    refute_received :verified
    refute_received {:handled, _}
  end

  test "rejects malformed replies, mode substitution and token tampering before callbacks", %{
    mcp: mcp
  } do
    {:ok, _, state} = Test.call_tool(mcp, "connect", %{})

    for reply <- [
          nil,
          %{},
          %{"action" => "bad"},
          %{"action" => "accept", "content" => %{}},
          %{"action" => "accept", "content" => nil}
        ] do
      assert resume(mcp, %{}, state, reply) == {:error, :invalid_params}
    end

    for responses <- [
          %{"form" => %{"action" => "accept"}},
          %{"form" => %{"action" => "cancel"}, "url" => %{"action" => "cancel"}}
        ] do
      assert Test.call_tool(mcp, "connect", %{}, request_state: state, input_responses: responses) ==
               {:error, :invalid_params}
    end

    assert resume(mcp, %{}, state <> "x", %{"action" => "accept"}) ==
             {:error, :invalid_request_state}

    assert resume(mcp, %{"different" => true}, state, %{"action" => "accept"}) ==
             {:error, :invalid_request_state}

    assert Test.call_tool(mcp, "other", %{}, request_state: state) ==
             {:error, :invalid_request_state}

    refute_received :verified
    refute_received {:handled, _}
  end

  test "a URL reply cannot be substituted for a signed form reply", %{mcp: mcp} do
    {:ok, form} =
      Input.form("Name?",
        schema: %{
          type: "object",
          properties: %{name: %{type: "string"}}
        }
      )

    request = %Portico.Request{server: Server, tool_name: "connect", arguments: %{}}
    {:ok, state} = Portico.Elicitation.seal(form, "flow", request)
    context = %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}, "url" => %{}}}}
    assert resume(context, %{}, state, %{"action" => "cancel"}) == {:error, :invalid_params}
    refute_received :verified
    refute_received {:handled, _}
  end

  test "forged URL inputs are validated before being signed", %{mcp: mcp} do
    request = %Portico.Request{
      server: Server,
      tool_name: "connect",
      client_capabilities: mcp.client_capabilities
    }

    for input <- [
          %Input{mode: :url, url: "javascript:bad", message: "bad"},
          %Input{mode: :url, url: "https://example.com", message: "bad", schema: %{}},
          %Input{mode: :other, message: "bad"}
        ] do
      assert {:error, _} = Portico.Protocol.Elicitation.encode(input, "flow", request)
    end
  end

  defp resume(mcp, args, state, reply),
    do:
      Test.call_tool(mcp, "connect", args,
        request_state: state,
        input_responses: %{"url" => reply}
      )

  defp http(args, extra \\ %{}, capabilities \\ %{"elicitation" => %{"url" => %{}}}) do
    params =
      Map.merge(
        %{
          "name" => "connect",
          "arguments" => args,
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => capabilities
          }
        },
        extra
      )

    conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => params
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "connect")
      |> Portico.Plug.call(Portico.Plug.init(server: Server))

    body = conn.resp_body |> String.split("data: ") |> List.last() |> String.trim()
    {conn.status, JSON.decode!(body)}
  end
end
