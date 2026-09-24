defmodule Portico.Plug do
  @moduledoc """
  Serves completed MCP JSON responses through a host application's HTTP listener.

  Mount in a Phoenix router (outside a browser/CSRF pipeline):

      forward "/mcp", Portico.Plug,
        server: MyApp.MCP,
        allowed_origins: ["https://my-app.example"],
        assigns: [:current_user]

  In a `Plug.Router`, use `forward "/mcp", to: Portico.Plug,
  init_opts: [server: MyApp.MCP]`. The host application owns the listener.

  Options:

    * `:server` — required Portico server module.
    * `:allowed_origins` — exact Origin values to accept, default `[]`.
      Requests without Origin are accepted; duplicate Origin headers are rejected.
    * `:assigns` — atom keys to copy from `conn.assigns` into each fresh
      `Portico.Request`, default `[]`. Run authentication plugs before this plug.
    * `:max_body_bytes` — raw JSON body limit, default 1,000,000 bytes.

  Supports raw bodies and JSON bodies decoded by `Plug.Parsers`. When a parser
  runs first, configure its size limit and error handling upstream; this plug
  cannot measure the original body or handle errors raised before it runs.
  Query parameters never become protocol fields. Raw reads time out after
  15 seconds per read; the host owns overall request timeouts.

  Clients must send JSON and accept both `application/json` and
  `text/event-stream`, as required by MCP 2026-07-28. This initial adapter
  returns JSON only. Valid notifications are ignored with an empty 202 response.
  All responses halt the connection. No listener, sessions, CORS response headers,
  streaming, or authentication scheme are installed by this plug. Full schema
  validation and custom `Mcp-Param` header annotations are not supported yet.
  """

  @behaviour Plug
  import Plug.Conn
  alias Portico.Protocol.{Dispatcher, Error, Validation}
  alias Portico.Transport.Headers

  @impl true
  def init(options) do
    options =
      Keyword.validate!(options,
        server: nil,
        allowed_origins: [],
        assigns: [],
        max_body_bytes: 1_000_000
      )

    server = options[:server]

    unless is_atom(server) and server not in [nil, true, false],
      do: raise(ArgumentError, "expected :server to be a module")

    unless is_list(options[:allowed_origins]) and
             Enum.all?(options[:allowed_origins], &is_binary/1),
           do: raise(ArgumentError, "expected :allowed_origins to be a list of strings")

    unless is_list(options[:assigns]) and Enum.all?(options[:assigns], &is_atom/1),
      do: raise(ArgumentError, "expected :assigns to be a list of atom keys")

    unless is_integer(options[:max_body_bytes]) and options[:max_body_bytes] > 0,
      do: raise(ArgumentError, "expected :max_body_bytes to be a positive integer")

    Map.new(options)
  end

  @impl true
  def call(conn, options) do
    cond do
      not allowed_origin?(conn, options.allowed_origins) -> finish(conn, 403)
      conn.method != "POST" -> conn |> put_resp_header("allow", "POST") |> finish(405)
      not json_content?(conn) -> finish(conn, 415)
      not accepts_responses?(conn) -> finish(conn, 406)
      true -> read_message(conn, options)
    end
  end

  defp allowed_origin?(conn, allowed) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin in allowed
      _ -> false
    end
  end

  defp json_content?(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> match?({:ok, "application", "json", _}, Plug.Conn.Utils.content_type(value))
      _ -> false
    end
  end

  defp accepts_responses?(conn) do
    types =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&Plug.Conn.Utils.list/1)
      |> Enum.flat_map(fn value ->
        case Plug.Conn.Utils.media_type(value) do
          {:ok, type, subtype, params} ->
            case Float.parse(Map.get(params, "q", "1")) do
              {q, ""} when q > 0 and q <= 1 -> [{type, subtype}]
              _ -> []
            end

          _ ->
            []
        end
      end)

    {"application", "json"} in types and {"text", "event-stream"} in types
  end

  defp read_message(%{body_params: %Plug.Conn.Unfetched{}} = conn, options) do
    read_raw(conn, options, [], 0)
  end

  defp read_message(conn, options), do: dispatch(conn, conn.body_params, options)

  defp read_raw(conn, options, chunks, size) do
    remaining = options.max_body_bytes - size + 1

    case read_body(conn,
           length: remaining,
           read_length: min(remaining, 64_000),
           read_timeout: 15_000
         ) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > options.max_body_bytes ->
            finish(conn, 413)

          status == :more ->
            read_raw(conn, options, [chunk | chunks], size)

          true ->
            body = [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary()

            case JSON.decode(body) do
              {:ok, message} -> dispatch(conn, message, options)
              {:error, _} -> reply(conn, Error.response(:parse_error))
            end
        end

      {:error, :timeout} ->
        finish(conn, 408)

      {:error, _} ->
        finish(conn, 400)
    end
  end

  defp dispatch(conn, message, options) do
    # Validate structure before comparing headers. The dispatcher remains the
    # authority for protocol errors and never executes an invalid message.
    header_check =
      with {:ok, :request, request} <- Validation.envelope(message),
           {:ok, _metadata} <- Validation.request_metadata(Map.get(request, "params", %{})) do
        Headers.validate(conn.req_headers, request)
      end

    case header_check do
      {:error, :header_mismatch} ->
        reply(conn, Error.response(:header_mismatch, message["id"]))

      _ ->
        assigns = Map.take(conn.assigns, options.assigns)

        case Dispatcher.dispatch(options.server, message, assigns) do
          :no_response -> finish(conn, 202)
          {:reply, response} -> reply(conn, response)
        end
    end
  end

  defp reply(conn, response) do
    status =
      case response do
        %{"error" => %{"code" => -32601}} -> 404
        %{"error" => %{"code" => -32603}} -> 500
        %{"error" => _} -> 400
        _ -> 200
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(response))
    |> halt()
  end

  defp finish(conn, status), do: conn |> send_resp(status, "") |> halt()
end
