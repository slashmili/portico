defmodule Portico.Protocol.Error do
  @moduledoc false

  @type reason :: :invalid_request | :invalid_params | :method_not_found

  @doc """
  Builds a JSON-ready error response for a validation or method lookup failure.

  A known ID is preserved. `nil` means the ID could not be determined and is
  omitted from the response, as required by the targeted MCP revision. Invalid
  IDs must not be passed through; callers should use `nil` in that case.

  Messages are fixed and contain no request payloads. These are protocol errors,
  not tool execution results. Notification suppression and HTTP status codes
  belong to the dispatcher and transport, respectively.
  """
  @spec response(reason(), String.t() | integer() | nil) :: map()
  def response(reason, id \\ nil)
      when reason in [:invalid_request, :invalid_params, :method_not_found] do
    response = %{"jsonrpc" => "2.0", "error" => details(reason)}

    cond do
      is_nil(id) ->
        response

      is_integer(id) or (is_binary(id) and String.valid?(id)) ->
        Map.put(response, "id", id)

      true ->
        raise ArgumentError, "expected a string or integer request ID, or nil when unknown"
    end
  end

  defp details(:invalid_request), do: %{"code" => -32600, "message" => "Invalid request"}
  defp details(:invalid_params), do: %{"code" => -32602, "message" => "Invalid params"}
  defp details(:method_not_found), do: %{"code" => -32601, "message" => "Method not found"}
end
