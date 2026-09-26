defmodule Portico.Transport.Subscription do
  @moduledoc false
  import Plug.Conn
  require Logger
  alias Portico.Protocol.{Dispatcher, Encoder, Error}

  def call(conn, execution, timeout) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    meta = %{"io.modelcontextprotocol/subscriptionId" => execution.request.id}

    emit = fn
      :heartbeat, conn ->
        write(conn, ": keep-alive\n\n")

      {:ack, uris}, conn ->
        filter = if uris == [], do: %{}, else: %{"resourceSubscriptions" => uris}

        event(conn, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/subscriptions/acknowledged",
          "params" => %{"_meta" => meta, "notifications" => filter}
        })

      {:resource_updated, uri}, conn ->
        event(conn, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/resources/updated",
          "params" => %{"_meta" => meta, "uri" => uri}
        })
    end

    case write(conn, ": connected\n\n") do
      {:error, conn} ->
        halt(conn)

      {:ok, conn} ->
        case Portico.Subscription.Runner.run(execution, conn, emit, timeout) do
          {:ok, conn} ->
            {:reply, response} = Dispatcher.complete(execution.server, execution.request.id, %{})
            response = update_in(response, ["result", "_meta"], &Map.merge(&1, meta))
            finish(conn, response)

          {:error, reason, conn} ->
            Logger.error(fn -> "Portico subscription failed: #{inspect(reason)}" end)
            response = Error.response(:internal_error, execution.request.id)
            finish(conn, put_in(response, ["error", "data"], %{"_meta" => meta}))

          {:closed, conn} ->
            halt(conn)
        end
    end
  end

  defp finish(conn, response) do
    {_, conn} = event(conn, response)
    halt(conn)
  end

  defp event(conn, message) do
    {:ok, body} = Encoder.json(message)
    write(conn, ["event: message\ndata: ", body, "\n\n"])
  end

  defp write(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, conn}
    end
  end
end
