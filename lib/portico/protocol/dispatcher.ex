defmodule Portico.Protocol.Dispatcher do
  @moduledoc false

  alias Portico.{Request, Result, Server}
  alias Portico.Protocol.{Encoder, Error, Validation}

  @supported_versions ["2026-07-28"]

  @doc """
  Processes a decoded protocol message through the current validation stages.

  Returns a JSON-ready reply or `:no_response` for a valid notification.
  Optional application assigns are copied into the fresh request context.
  Envelope errors take precedence over request metadata errors. Notifications
  are ignored; no notification handlers are implemented yet.

  Checks the protocol version on every request before method lookup. Currently
  `server/discover`, `tools/list`, and completed text `tools/call` are implemented.
  Discovery advertises basic tools support. Listing returns the whole
  static catalog in name order and issues no pagination cursors. Discovery and
  listing use private cache scope with zero TTL (immediately stale). This is an incremental
  dispatcher, not a complete MCP implementation; full metadata validation,
  and schema validation are still pending. Test helpers use `call_tool_request/3`
  for the same validation and execution with exceptions left visible to tests.
  """
  @spec dispatch(module(), term(), map()) :: {:reply, map()} | :no_response
  def dispatch(server, message, assigns \\ %{}) when is_map(assigns) do
    case prepare(message, assigns) do
      {:ok, message, context} -> dispatch_method(server, message, context)
      :no_response -> :no_response
      {:error, reason} -> {:reply, Error.response(reason, readable_id(message))}
    end
  end

  @doc false
  def call_tool_request(server, message, assigns) do
    case prepare(message, assigns) do
      {:ok, %{"method" => "tools/call", "params" => params}, context} ->
        case execute_call(server, params, context) do
          {:ok, result, _fields} -> {:ok, result}
          {:error, _reason} = error -> error
        end

      {:ok, _message, _context} ->
        {:error, :method_not_found}

      :no_response ->
        {:error, :invalid_request}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare(message, assigns) do
    case Validation.envelope(message) do
      {:error, :invalid_request} = error ->
        error

      {:ok, :notification, _notification} ->
        :no_response

      {:ok, :request, request} ->
        params = Map.get(request, "params", %{})

        with {:ok, metadata} <- Validation.request_metadata(params) do
          version = metadata["io.modelcontextprotocol/protocolVersion"]

          if version in @supported_versions do
            context = %Request{
              id: request["id"],
              method: request["method"],
              protocol_version: version,
              client_info: metadata["io.modelcontextprotocol/clientInfo"],
              client_capabilities: metadata["io.modelcontextprotocol/clientCapabilities"],
              assigns: assigns
            }

            {:ok, request, context}
          else
            {:error, {:unsupported_protocol_version, version, @supported_versions}}
          end
        end
    end
  end

  defp dispatch_method(server, %{"method" => "server/discover", "id" => id}, _context) do
    complete(server, id, %{
      "supportedVersions" => @supported_versions,
      "cacheScope" => "private",
      "ttlMs" => 0,
      "capabilities" => %{"tools" => %{}}
    })
  end

  defp dispatch_method(
         server,
         %{"method" => "tools/list", "id" => id, "params" => params},
         _context
       ) do
    if Map.has_key?(params, "cursor") do
      {:reply, Error.response(:invalid_params, id)}
    else
      tools = Enum.map(Server.tools(server), &tool_metadata/1)
      complete(server, id, %{"tools" => tools, "cacheScope" => "private", "ttlMs" => 0})
    end
  end

  defp dispatch_method(server, %{"method" => "tools/call", "params" => params}, context) do
    invoke(server, params, context)
  end

  defp dispatch_method(_server, request, _context) do
    {:reply, Error.response(:method_not_found, request["id"])}
  end

  defp invoke(server, params, request) do
    case execute_call(server, params, request) do
      {:error, reason} when reason in [:unknown_tool, :invalid_params] ->
        {:reply, Error.response(:invalid_params, request.id)}

      {:ok, _result, fields} ->
        complete(server, request.id, fields)
    end
  rescue
    _error -> {:reply, Error.response(:internal_error, request.id)}
  end

  defp execute_call(server, params, request) do
    with {:ok, name, arguments} <- Validation.tool_call(params),
         {:ok, result} <- call_tool(server, name, arguments, request) do
      case Encoder.tool_result(result) do
        {:ok, fields} -> {:ok, result, fields}
        {:error, :invalid_result} -> raise ArgumentError, "invalid tool result content"
      end
    end
  end

  defp tool_metadata(tool) do
    metadata = %{"name" => tool.name, "inputSchema" => tool.input_schema}

    case Map.fetch(tool, :description) do
      {:ok, description} -> Map.put(metadata, "description", description)
      :error -> metadata
    end
  end

  defp complete(server, id, fields) do
    info = Server.info(server)

    {:reply,
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" =>
         Map.merge(fields, %{
           "resultType" => "complete",
           "_meta" => %{
             "io.modelcontextprotocol/serverInfo" => %{
               "name" => info.name,
               "version" => info.version
             }
           }
         })
     }}
  end

  defp readable_id(%{"id" => id}) when is_integer(id), do: id

  defp readable_id(%{"id" => id}) when is_binary(id) do
    if String.valid?(id), do: id, else: nil
  end

  defp readable_id(_message), do: nil

  @spec call_tool(module(), String.t(), map(), Request.t()) ::
          {:ok, Result.t()} | {:error, :unknown_tool}
  def call_tool(server, name, arguments, %Request{} = request) when is_binary(name) do
    unless is_map(arguments) and not is_struct(arguments) do
      raise ArgumentError, "expected tool arguments to be a plain map"
    end

    case Enum.find(Server.tools(server), &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      %{module: module} ->
        case module.call(arguments, request) do
          {:ok, %Result{}} = reply ->
            reply

          _other ->
            raise ArgumentError,
                  "invalid return from #{inspect(module)}.call/2; " <>
                    "expected {:ok, %Portico.Result{}}"
        end
    end
  end
end
