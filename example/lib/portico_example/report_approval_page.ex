defmodule PorticoExample.ReportApprovalPage do
  @moduledoc false
  import Plug.Conn
  alias PorticoExample.ReportApprovals

  # Fixed public credentials demonstrate identity binding on loopback only.
  # This is not MCP OAuth or a production authentication system.
  def user(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {"alice", "alice-demo"} -> "alice"
      {"bob", "bob-demo"} -> "bob"
      _ -> nil
    end
  end

  def call(conn, id) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; form-action 'self'; frame-ancestors 'none'"
      )

    case user(conn) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="Portico local demo"))
        |> send_resp(401, "Demo login required")

      user ->
        respond(conn, id, user)
    end
  end

  defp respond(%{method: "GET"} = conn, id, user) do
    case ReportApprovals.get(id, user) do
      {:ok, entry} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, """
        <!doctype html><html lang="en"><meta charset="utf-8"><title>Review demo report</title>
        <h1>Review demo report</h1><p>Signed in as #{user}. Sample report: 3 orders, total 42 EUR. This is fictional data.</p>
        #{decision_form(entry)}
        </html>
        """)

      {:error, _} ->
        send_resp(conn, 404, "Report approval not found or expired")
    end
  end

  defp respond(%{method: "POST"} = conn, id, user) do
    with ["application/x-www-form-urlencoded" <> _] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <- read_body(conn, length: 2_048),
         %{"confirmation" => confirmation, "decision" => decision} <- decode(body),
         {:ok, status} <- decision(decision),
         :ok <- ReportApprovals.decide(id, user, confirmation, status) do
      send_resp(
        conn,
        200,
        "Report #{status}. Return to your MCP client and retry the request."
      )
    else
      _ -> send_resp(conn, 400, "Invalid confirmation")
    end
  end

  defp decision_form(%{status: :pending} = entry) do
    """
    <form method="post"><input type="hidden" name="confirmation" value="#{entry.confirmation}">
    <button type="submit" name="decision" value="approve">Approve report</button>
    <button type="submit" name="decision" value="reject">Reject report</button></form>
    """
  end

  defp decision_form(entry),
    do: "<p>Report #{entry.status}. Return to your MCP client and retry the request.</p>"

  defp decision("approve"), do: {:ok, :approved}
  defp decision("reject"), do: {:ok, :rejected}
  defp decision(_), do: {:error, :invalid_decision}

  defp decode(body) do
    URI.decode_query(body)
  rescue
    ArgumentError -> %{}
  end
end
