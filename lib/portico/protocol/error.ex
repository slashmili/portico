defmodule Portico.Protocol.Error do
  @moduledoc false

  @type reason ::
          :parse_error
          | :invalid_request
          | :invalid_params
          | :resource_not_found
          | :method_not_found
          | :internal_error
          | :header_mismatch
          | :form_not_supported
          | :url_not_supported
          | :sampling_not_supported
          | {:unsupported_protocol_version, String.t(), [String.t()]}

  @doc """
  Builds a JSON-ready error response for a validation or method lookup failure.

  A known ID is preserved. `nil` means the ID could not be determined and is
  omitted from the response, as required by the targeted MCP revision. Invalid
  IDs return `{:error, :invalid_id}`. Unsupported or malformed reasons return
  `{:error, :invalid_reason}`. IDs are validated first.

  Messages are fixed. Version mismatch data contains only requested and supported
  versions, not the complete request payload. These are protocol errors,
  not tool execution results. Notification suppression and HTTP status codes
  belong to the dispatcher and transport, respectively.
  """
  @spec response(reason(), String.t() | integer() | nil) ::
          map() | {:error, :invalid_id | :invalid_reason}
  def response(reason, id \\ nil) do
    with :ok <- valid_id(id),
         %{} = details <- details(reason) do
      response = %{"jsonrpc" => "2.0", "error" => details}
      if is_nil(id), do: response, else: Map.put(response, "id", id)
    end
  end

  defp valid_id(id) when is_nil(id) or is_integer(id), do: :ok

  defp valid_id(id) when is_binary(id) do
    if String.valid?(id), do: :ok, else: {:error, :invalid_id}
  end

  defp valid_id(_id), do: {:error, :invalid_id}

  defp details(:parse_error), do: %{"code" => -32700, "message" => "Parse error"}
  defp details(:invalid_request), do: %{"code" => -32600, "message" => "Invalid request"}
  defp details(:invalid_params), do: %{"code" => -32602, "message" => "Invalid params"}
  defp details(:resource_not_found), do: %{"code" => -32602, "message" => "Resource not found"}
  defp details(:method_not_found), do: %{"code" => -32601, "message" => "Method not found"}
  defp details(:internal_error), do: %{"code" => -32603, "message" => "Internal error"}
  defp details(:header_mismatch), do: %{"code" => -32020, "message" => "Header mismatch"}

  defp details(:sampling_not_supported) do
    %{
      "code" => -32021,
      "message" => "Missing required client capability",
      "data" => %{"requiredCapabilities" => %{"sampling" => %{}}}
    }
  end

  defp details(reason) when reason in [:form_not_supported, :url_not_supported] do
    mode = if reason == :url_not_supported, do: "url", else: "form"

    %{
      "code" => -32021,
      "message" => "Missing required client capability",
      "data" => %{"requiredCapabilities" => %{"elicitation" => %{mode => %{}}}}
    }
  end

  defp details({:unsupported_protocol_version, requested, supported})
       when is_binary(requested) and is_list(supported) do
    if String.valid?(requested) and
         Enum.all?(supported, &(is_binary(&1) and String.valid?(&1))) do
      %{
        "code" => -32022,
        "message" => "Unsupported protocol version",
        "data" => %{"requested" => requested, "supported" => supported}
      }
    else
      {:error, :invalid_reason}
    end
  end

  defp details(_reason), do: {:error, :invalid_reason}
end
