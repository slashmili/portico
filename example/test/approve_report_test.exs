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
    refute entry.complete
    assert request(:post, path, "alice", "confirmation=wrong").status == 400

    assert request(:post, path, "bob", URI.encode_query(%{confirmation: entry.confirmation})).status ==
             400

    assert request(:post, path, "alice", "confirmation=%ZZ").status == 400

    assert {:ok, %Portico.Input{mode: :url}, _} =
             call_tool(mcp, "approve_report", %{},
               request_state: state,
               input_responses: %{"url" => %{"action" => "accept"}}
             )

    assert request(:post, path, "alice", URI.encode_query(%{confirmation: entry.confirmation})).status ==
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
