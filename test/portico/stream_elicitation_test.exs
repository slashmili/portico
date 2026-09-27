defmodule Portico.StreamElicitationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  alias Portico.{Input, Result}
  alias Portico.Test.Context

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(args, _request), do: {:noreply, args, :stream}
    @impl true
    def handle_stream(args, stream) do
      if pid = stream.request.assigns[:observer], do: send(pid, {:worker, self()})
      :ok = Portico.Stream.send(stream, {:progress, 1, total: 1, message: "Ready"})

      {:ok, form} =
        Input.form("Name?",
          schema: %{
            type: "object",
            properties: %{name: %{type: "string", minLength: 1}},
            required: ["name"]
          }
        )

      case args["mode"] do
        "bad_form" -> {:ok, %{form | schema: %{}}, "state"}
        "bad_state" -> {:ok, form, nil}
        _ -> {:ok, form, "state"}
      end
    end

    @impl true
    def handle_input({:accept, %{"name" => name}}, "state", _), do: Result.text("Hello, #{name}!")
    def handle_input(:decline, "state", _), do: Result.error("Declined")
    def handle_input(:cancel, "state", _), do: Result.text("Cancelled")
  end

  defmodule Missing do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    defdelegate call(args, request), to: Tool
    @impl true
    defdelegate handle_stream(args, stream), to: Tool
  end

  defmodule Server do
    use Portico.Server, name: "stream-forms", version: "1"
    tool "work", Tool
    tool "missing", Missing
  end

  setup do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("s", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    %{
      mcp: %Context{
        server: Server,
        client_capabilities: %{"elicitation" => %{"form" => %{}}},
        assigns: %{observer: self()}
      }
    }
  end

  defp http(args, extra \\ %{}, capabilities \\ %{"elicitation" => %{"form" => %{}}}) do
    params =
      Map.merge(
        %{
          "name" => "work",
          "arguments" => args,
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => capabilities,
            "progressToken" => "p"
          }
        },
        extra
      )

    conn(
      :post,
      "/mcp",
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => 8, "method" => "tools/call", "params" => params})
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", params["name"])
    |> assign(:observer, self())
    |> Portico.Plug.call(Portico.Plug.init(server: Server, assigns: [:observer]))
  end

  defp events(conn) do
    for "data: " <> json <- String.split(conn.resp_body, "\n"), do: JSON.decode!(json)
  end

  test "stream ends with a protected form after progress, and worker exits before the reply" do
    conn = http(%{})
    assert conn.status == 200 and conn.halted
    assert [progress, form] = events(conn)
    assert progress["method"] == "notifications/progress"
    assert form["id"] == 8
    assert form["result"]["resultType"] == "input_required"
    assert form["result"]["inputRequests"]["form"]["method"] == "elicitation/create"
    assert_received {:worker, worker}
    refute Process.alive?(worker)
    token = form["result"]["requestState"]

    reply =
      http(%{}, %{
        "requestState" => token,
        "inputResponses" => %{"form" => %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      })

    assert JSON.decode!(reply.resp_body)["result"]["content"] == [
             %{"type" => "text", "text" => "Hello, Ada!"}
           ]

    refute_received {:worker, _}
  end

  test "direct helpers collect progress then return the form for accept, decline or cancel", %{
    mcp: mcp
  } do
    owner = self()

    {:ok, %Input{}, token} =
      Portico.Test.call_tool(mcp, "work", %{},
        on_progress: fn update -> send(owner, {:progress, update}) end
      )

    assert_received {:progress, %{progress: 1}}

    for {action, content} <- [{"accept", %{"name" => "Ada"}}, {"decline", %{}}, {"cancel", %{}}] do
      assert {:ok, %Result{}} =
               Portico.Test.call_tool(mcp, "work", %{},
                 request_state: token,
                 input_responses: %{"form" => %{"action" => action, "content" => content}}
               )
    end

    assert {:ok, %Input{}, _} =
             Portico.Test.call_tool(mcp, "work", %{},
               request_state: token,
               input_responses: %{"form" => %{"action" => "accept", "content" => %{"name" => ""}}}
             )

    assert {:error, :invalid_request_state} =
             Portico.Test.call_tool(mcp, "work", %{}, request_state: token <> "x")
  end

  test "unsupported clients get a protocol error after progress", %{mcp: mcp} do
    for capabilities <- [%{}, %{"elicitation" => %{"url" => %{}}}] do
      assert {:error, :form_not_supported} =
               Portico.Test.call_tool(%{mcp | client_capabilities: capabilities}, "work", %{})

      conn = http(%{}, %{}, capabilities)
      assert conn.status == 200 and conn.halted
      assert [progress, response] = events(conn)
      assert progress["method"] == "notifications/progress"
      assert response == Portico.Protocol.Error.response(:form_not_supported, 8)
    end
  end

  test "invalid forms, states and missing reply callbacks fail safely", %{mcp: mcp} do
    for {args, reason} <- [
          {%{"mode" => "bad_form"}, :invalid_schema},
          {%{"mode" => "bad_state"}, :invalid_request_state}
        ] do
      assert {:error, ^reason} = Portico.Test.call_tool(mcp, "work", args)
      assert [_, response] = events(http(args))
      assert response["error"]["code"] == -32603
    end

    assert {:error, :missing_input_callback} = Portico.Test.call_tool(mcp, "missing", %{})
    assert [_, response] = events(http(%{}, %{"name" => "missing"}))
    assert response["error"]["code"] == -32603
  end
end
