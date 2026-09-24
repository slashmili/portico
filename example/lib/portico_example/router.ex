defmodule PorticoExample.Router do
  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  match "/mcp" do
    options =
      Portico.Plug.init(
        server: PorticoExample.MCP,
        allowed_origins: Application.fetch_env!(:portico_example, :allowed_origins)
      )

    Portico.Plug.call(conn, options)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
