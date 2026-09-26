defmodule PorticoExample.ReviewedReportTest do
  use Portico.Test, server: PorticoExample.MCP, async: true
  alias PorticoExample.ReportApprovals

  setup %{mcp: mcp} do
    %{
      mcp: %{
        mcp
        | assigns: %{demo_user: "alice"},
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
      }
    }
  end

  test "checks browser completion and identity before returning the report", %{mcp: mcp} do
    {:ok, input, state} = read_resource mcp, "company://reviewed-report"
    id = input.url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    options = [request_state: state, input_responses: %{"url" => %{"action" => "accept"}}]

    assert {:ok, ^input, _} = read_resource(mcp, "company://reviewed-report", options)
    {:ok, entry} = ReportApprovals.get(id, "alice")
    :ok = ReportApprovals.complete(id, "alice", entry.confirmation)

    {:ok, content} = read_resource mcp, "company://reviewed-report", options
    assert content.text == "Reviewed sample report: 3 orders, total 42 EUR."
    assert content.uri == "company://reviewed-report"

    assert {:error, :not_found} =
             read_resource(
               %{mcp | assigns: %{demo_user: "bob"}},
               "company://reviewed-report",
               options
             )
  end

  test "decline and cancel return status text without report data", %{mcp: mcp} do
    {:ok, _, state} = read_resource mcp, "company://reviewed-report"

    for {action, text} <- [
          {"decline", "Report approval declined."},
          {"cancel", "Report approval cancelled."}
        ] do
      {:ok, content} =
        read_resource mcp, "company://reviewed-report",
          request_state: state,
          input_responses: %{"url" => %{"action" => action}}

      assert content.text == text
    end

    {:ok, content} = read_resource %{mcp | assigns: %{}}, "company://reviewed-report"
    assert content.text =~ "Use demo Basic auth"
  end
end
