defmodule PorticoExample.ApproveReportTest do
  use Portico.Test, server: PorticoExample.MCP, async: true
  import Plug.Test
  import Plug.Conn
  alias PorticoExample.{ReportApprovals, Router}

  test "browser confirmation binds the demo identity and requires a confirmation token", %{
    mcp: mcp
  } do
    mcp = %{
      mcp
      | assigns: %{demo_user: "alice"},
        client_capabilities: %{"elicitation" => %{"url" => %{}}}
    }

    {:ok, input, state} = call_tool mcp, "approve_report", %{}
    path = URI.parse(input.url).path
    id = Path.basename(path)
    assert request(:get, path, nil).status == 401
    assert request(:get, path, "bob").status == 404
    assert request(:get, path, "alice").status == 200
    {:ok, entry} = ReportApprovals.get(id, "alice")
    assert entry.status == :pending
    assert request(:post, path, "alice", "confirmation=wrong").status == 400

    assert request(
             :post,
             path,
             "bob",
             URI.encode_query(%{confirmation: entry.confirmation, decision: "approve"})
           ).status ==
             400

    assert request(:post, path, "alice", "confirmation=%ZZ").status == 400

    assert {:ok, %Portico.Input{mode: :url}, _} =
             call_tool(mcp, "approve_report", %{},
               request_state: state,
               input_responses: %{"url" => %{"action" => "accept"}}
             )

    assert request(
             :post,
             path,
             "alice",
             URI.encode_query(%{confirmation: entry.confirmation, decision: "approve"})
           ).status ==
             200

    {:ok, result} =
      call_tool mcp, "approve_report", %{},
        request_state: state,
        input_responses: %{"url" => %{"action" => "accept"}}

    assert_text result, "Demo report approved."

    assert {:error, :not_found} =
             call_tool(%{mcp | assigns: %{demo_user: "bob"}}, "approve_report", %{},
               request_state: state,
               input_responses: %{"url" => %{"action" => "accept"}}
             )
  end

  test "browser rejection is final and reaches both tool and resource callers", %{mcp: mcp} do
    mcp = %{
      mcp
      | assigns: %{demo_user: "alice"},
        client_capabilities: %{"elicitation" => %{"url" => %{}}}
    }

    for kind <- [:tool, :resource] do
      invoke = fn options ->
        case kind do
          :tool -> call_tool(mcp, "approve_report", %{}, options)
          :resource -> read_resource(mcp, "company://reviewed-report", options)
        end
      end

      {:ok, input, state} = invoke.([])
      path = URI.parse(input.url).path
      id = Path.basename(path)
      {:ok, entry} = ReportApprovals.get(id, "alice")
      body = URI.encode_query(%{confirmation: entry.confirmation, decision: "reject"})
      assert request(:get, path, "alice").resp_body =~ "Reject report"
      assert request(:post, path, "bob", body).status == 400

      assert request(:post, path, "alice", URI.encode_query(%{confirmation: entry.confirmation})).status ==
               400

      assert request(
               :post,
               path,
               "alice",
               URI.encode_query(%{confirmation: entry.confirmation, decision: "other"})
             ).status == 400

      assert request(:post, path, "alice", "confirmation=wrong&decision=reject").status == 400
      assert request(:post, path, "alice", body).status == 200
      assert request(:post, path, "alice", body).status == 200

      assert request(
               :post,
               path,
               "alice",
               URI.encode_query(%{confirmation: entry.confirmation, decision: "approve"})
             ).status == 400

      {:ok, decided} = ReportApprovals.get(id, "alice")
      assert decided.status == :rejected
      refute request(:get, path, "alice").resp_body =~ "<form"

      {:ok, result} =
        invoke.(request_state: state, input_responses: %{"url" => %{"action" => "accept"}})

      case kind do
        :tool ->
          assert_text result, "Report approval rejected."
          assert result.is_error

        :resource ->
          assert result.text == "Report approval rejected."
      end
    end
  end

  defp request(method, path, user, body \\ "") do
    conn = conn(method, path, body)

    conn =
      if user,
        do:
          put_req_header(
            conn,
            "authorization",
            "Basic " <> Base.encode64(user <> ":" <> user <> "-demo")
          ),
        else: conn

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(Router.init([]))
  end
end
