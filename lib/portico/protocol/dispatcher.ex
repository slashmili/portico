defmodule Portico.Protocol.Dispatcher do
  @moduledoc false

  alias Portico.{Request, Result, Server}
  alias Portico.Protocol.{Encoder, Error, Validation}

  @supported_versions ["2026-07-28"]

  @doc """
  Processes a decoded protocol message through the current validation stages.

  Returns a JSON-ready reply or `:no_response` for a valid notification.
  Envelope errors take precedence over request metadata errors. Notifications
  are ignored; no notification handlers are implemented yet.

  Checks the protocol version on every request before method lookup. Currently
  `server/discover`, `tools/list`, and completed text `tools/call` are implemented.
  Discovery advertises basic tools support. Listing returns the whole
  static catalog in name order and issues no pagination cursors. This is an incremental
  dispatcher, not a complete MCP implementation; HTTP, full metadata validation,
  and schema validation are still pending. Direct `call_tool/4` remains available
  for application tests.
  """
  @spec dispatch(module(), term()) :: {:reply, map()} | :no_response
  def dispatch(server, message) do
    case Validation.envelope(message) do
      {:error, :invalid_request} ->
        {:reply, Error.response(:invalid_request, readable_id(message))}

      {:ok, :notification, _notification} ->
        :no_response

      {:ok, :request, request} ->
        case Validation.request_metadata(Map.get(request, "params", %{})) do
          {:error, :invalid_params} ->
            {:reply, Error.response(:invalid_params, request["id"])}

          {:ok, metadata} ->
            version = metadata["io.modelcontextprotocol/protocolVersion"]

            if version in @supported_versions do
              dispatch_method(server, request)
            else
              reason = {:unsupported_protocol_version, version, @supported_versions}
              {:reply, Error.response(reason, request["id"])}
            end
        end
    end
  end

  defp dispatch_method(server, %{"method" => "server/discover", "id" => id}) do
    complete(server, id, %{
      "supportedVersions" => @supported_versions,
      "capabilities" => %{"tools" => %{}}
    })
  end

  defp dispatch_method(server, %{"method" => "tools/list", "id" => id, "params" => params}) do
    if Map.has_key?(params, "cursor") do
      {:reply, Error.response(:invalid_params, id)}
    else
      tools = Enum.map(Server.tools(server), &tool_metadata/1)
      complete(server, id, %{"tools" => tools})
    end
  end

  defp dispatch_method(server, %{"method" => "tools/call", "id" => id, "params" => params}) do
    case Validation.tool_call(params) do
      {:ok, name, arguments} ->
        metadata = params["_meta"]

        request = %Request{
          id: id,
          method: "tools/call",
          protocol_version: metadata["io.modelcontextprotocol/protocolVersion"],
          client_info: metadata["io.modelcontextprotocol/clientInfo"],
          client_capabilities: metadata["io.modelcontextprotocol/clientCapabilities"]
        }

        invoke(server, name, arguments, request)

      {:error, :invalid_params} ->
        {:reply, Error.response(:invalid_params, id)}
    end
  end

  defp dispatch_method(_server, request) do
    {:reply, Error.response(:method_not_found, request["id"])}
  end

  defp invoke(server, name, arguments, request) do
    case call_tool(server, name, arguments, request) do
      {:error, :unknown_tool} ->
        {:reply, Error.response(:invalid_params, request.id)}

      {:reply, result, _updated_request} ->
        case Encoder.tool_result(result) do
          {:ok, fields} -> complete(server, request.id, fields)
          {:error, :invalid_result} -> {:reply, Error.response(:internal_error, request.id)}
        end
    end
  rescue
    _error -> {:reply, Error.response(:internal_error, request.id)}
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
          {:reply, Result.t(), Request.t()} | {:error, :unknown_tool}
  def call_tool(server, name, arguments, %Request{} = request) when is_binary(name) do
    unless is_map(arguments) and not is_struct(arguments) do
      raise ArgumentError, "expected tool arguments to be a plain map"
    end

    case Enum.find(Server.tools(server), &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      %{module: module} ->
        case module.call(arguments, request) do
          {:reply, %Result{}, %Request{}} = reply ->
            reply

          _other ->
            raise ArgumentError,
                  "invalid return from #{inspect(module)}.call/2; " <>
                    "expected {:reply, %Portico.Result{}, %Portico.Request{}}"
        end
    end
  end
end
