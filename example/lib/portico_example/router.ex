defmodule PorticoExample.Router do
  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  match "/mcp" do
    options =
      Portico.Plug.init(
        server: PorticoExample.MCP,
        assigns: [:demo_user],
        allowed_origins: Application.fetch_env!(:portico_example, :allowed_origins)
      )

    conn
    |> assign(:demo_user, PorticoExample.ReportApprovalPage.user(conn))
    |> Portico.Plug.call(options)
  end

  get "/report-approvals/:id" do
    PorticoExample.ReportApprovalPage.call(conn, id)
  end

  post "/report-approvals/:id" do
    PorticoExample.ReportApprovalPage.call(conn, id)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
