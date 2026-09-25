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

          {:input, _form, _state, fields, conn} ->
            {:reply, response} =
              Dispatcher.input_required(execution.server, execution.request.id, fields)

            finish(conn, response)

          {:input_error, :form_not_supported, conn} ->
            finish(conn, Error.response(:form_not_supported, execution.request.id))

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

  defp event(conn, message) do
    case Encoder.json(message) do
      {:ok, body} ->
        write(conn, ["event: message\ndata: ", body, "\n\n"])

      {:error, :invalid_json} ->
        Logger.error("Portico stream encoding failed: :invalid_json")
        {_status, conn} = event(conn, Encoder.internal_error(message["id"]))
        {:error, conn}
    end
  end

  defp write(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end
end
