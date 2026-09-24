defmodule Portico.Protocol.Validation do
  @moduledoc false

  @doc """
  Checks one decoded JSON-RPC request or notification envelope.

  Preserves the message unchanged. An absent ID marks a notification; an
  explicit null ID is invalid. Accepts only string-keyed objects for the
  envelope and optional params, without converting strings to atoms.

  This is a shallow envelope check on decoded JSON, not a JSON decoder or a
  recursive JSON-value validator. MCP metadata, method-specific parameters,
  authorization, and input schemas are checked in later stages. Passing this
  check alone does not make a message a valid MCP request. Batch arrays and
  response messages are not accepted by this entry point.
  """
  @spec envelope(term()) ::
          {:ok, :request | :notification, map()} | {:error, :invalid_request}
  def envelope(%{"jsonrpc" => "2.0", "method" => method} = message) do
    if object?(message) and string?(method) and params_valid?(message) do
      case Map.fetch(message, "id") do
        :error ->
          {:ok, :notification, message}

        {:ok, id} ->
          if is_integer(id) or string?(id) do
            {:ok, :request, message}
          else
            {:error, :invalid_request}
          end
      end
    else
      {:error, :invalid_request}
    end
  end

  def envelope(_message), do: {:error, :invalid_request}

  @doc """
  Checks the core metadata fields in decoded request params.

  Requires a string protocol version and a client-capabilities object. Client
  information is optional; when supplied, it must contain string name and
  version fields. Returns the metadata unchanged, including extension fields.

  This is structural validation only. Supported-version checks, capability
  payloads, optional metadata fields, and metadata key naming rules are separate
  checks. Client information is self-reported and does not establish identity.
  This function applies to requests, not notifications. Errors will map to
  JSON-RPC Invalid params (-32602) when error encoding is implemented.
  """
  @spec request_metadata(term()) :: {:ok, map()} | {:error, :invalid_params}
  def request_metadata(%{"_meta" => meta} = params) do
    if object?(params) and object?(meta) and
         string?(meta["io.modelcontextprotocol/protocolVersion"]) and
         object?(meta["io.modelcontextprotocol/clientCapabilities"]) and client_info_valid?(meta) do
      {:ok, meta}
    else
      {:error, :invalid_params}
    end
  end

  def request_metadata(_params), do: {:error, :invalid_params}

  defp client_info_valid?(meta) do
    case Map.fetch(meta, "io.modelcontextprotocol/clientInfo") do
      :error ->
        true

      {:ok, info} ->
        object?(info) and string?(info["name"]) and string?(info["version"])
    end
  end

  defp params_valid?(message) do
    case Map.fetch(message, "params") do
      :error -> true
      {:ok, params} -> object?(params)
    end
  end

  defp object?(value) do
    is_map(value) and not is_struct(value) and Enum.all?(Map.keys(value), &string?/1)
  end

  defp string?(value), do: is_binary(value) and String.valid?(value)
end
