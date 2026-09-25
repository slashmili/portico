defmodule Portico.Transport.SSE do
  @moduledoc false
  require Logger
  import Plug.Conn
  alias Portico.Protocol.{Dispatcher, Encoder, Error}
  alias Portico.Stream.Runner

  def call(conn, execution, timeout) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # A comment flushes headers before work starts. Periodic comments also
    # detect disconnects while the callback is silent or blocked.
    case write(conn, ": connected\n\n") do
      {:error, conn} ->
        halt(conn)

      {:ok, conn} ->
        emit = fn
          :heartbeat, conn ->
            write(conn, ": keep-alive\n\n")

          {:progress, progress}, conn ->
            params =
              progress
              |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
              |> Map.put("progressToken", execution.request.progress_token)

            event(conn, %{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => params
            })
        end

        case Runner.run(execution, conn, emit, timeout) do
          {:ok, result, conn} ->
            {:ok, fields} = Encoder.tool_result(result)

            {:reply, response} =
              Dispatcher.complete(execution.server, execution.request.id, fields)

            finish(conn, response)

          {:error, reason, conn} ->
            Logger.error(fn -> "Portico stream failed: #{inspect(reason)}" end)
            finish(conn, Error.response(:internal_error, execution.request.id))

          {:failed, _kind, _reason, _stack, conn} ->
            finish(conn, Error.response(:internal_error, execution.request.id))

          {:closed, conn} ->
            halt(conn)
        end
    end
  end

  defp finish(conn, response) do
    {_status, conn} = event(conn, response)
    halt(conn)
  end

  defp event(conn, message),
    do: write(conn, ["event: message\ndata: ", JSON.encode!(message), "\n\n"])

  defp write(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end
end
