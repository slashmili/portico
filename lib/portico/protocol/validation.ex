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
  version fields. Optional title, description and websiteUrl are UTF-8 strings;
  icons are objects with string src, optional string mimeType, string-list sizes,
  and light/dark theme. This checks shapes, not URI/MIME/size formats, and never
  fetches icons. Unknown fields remain unchanged.
  An optional `progressToken` must be a string or integer;
  explicit null is invalid. Returns metadata unchanged, including extension fields.

  Elicitation and its optional `form`/`url` fields must be string-keyed objects.
  Empty declarations and unknown extension fields are preserved unchanged.

  This is structural validation only. Supported-version checks, other capability
  payloads, optional metadata fields, and metadata key naming rules are separate
  checks. Client information is self-reported and does not establish identity.
  This function applies to requests, not notifications. Errors map to
  JSON-RPC Invalid params (-32602).
  """
  @spec request_metadata(term()) :: {:ok, map()} | {:error, :invalid_params}
  def request_metadata(%{"_meta" => meta} = params) do
    if object?(params) and object?(meta) and
         string?(meta["io.modelcontextprotocol/protocolVersion"]) and
         capabilities_valid?(meta["io.modelcontextprotocol/clientCapabilities"]) and
         client_info_valid?(meta) and
         progress_token_valid?(meta) do
      {:ok, meta}
    else
      {:error, :invalid_params}
    end
  end

  def request_metadata(_params), do: {:error, :invalid_params}

  @doc "Checks tools/call parameter shape, without validating arguments against a schema."
  @spec tool_call(map()) :: {:ok, String.t(), map()} | {:error, :invalid_params}
  def tool_call(params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    if string?(name) and object?(arguments) do
      {:ok, name, arguments}
    else
      {:error, :invalid_params}
    end
  end

  defp capabilities_valid?(capabilities) do
    object?(capabilities) and
      case Map.fetch(capabilities, "elicitation") do
        :error ->
          true

        {:ok, elicitation} ->
          object?(elicitation) and
            Enum.all?(["form", "url"], fn mode ->
              case Map.fetch(elicitation, mode) do
                :error -> true
                {:ok, options} -> object?(options)
              end
            end)
      end
  end

  defp progress_token_valid?(meta) do
    case Map.fetch(meta, "progressToken") do
      :error -> true
      {:ok, token} -> is_integer(token) or string?(token)
    end
  end

  defp client_info_valid?(meta) do
    case Map.fetch(meta, "io.modelcontextprotocol/clientInfo") do
      :error ->
        true

      {:ok, info} ->
        object?(info) and string?(info["name"]) and string?(info["version"]) and
          Enum.all?(["title", "description", "websiteUrl"], fn key ->
            optional?(info, key, &string?/1)
          end) and
          optional?(info, "icons", fn icons -> list_of?(icons, &icon?/1) end)
    end
  end

  defp icon?(icon) do
    object?(icon) and string?(icon["src"]) and
      optional?(icon, "mimeType", &string?/1) and
      optional?(icon, "sizes", fn sizes -> list_of?(sizes, &string?/1) end) and
      optional?(icon, "theme", &(&1 in ["light", "dark"]))
  end

  defp optional?(object, key, valid?) do
    case Map.fetch(object, key) do
      :error -> true
      {:ok, value} -> valid?.(value)
    end
  end

  defp list_of?([], _valid?), do: true
  defp list_of?([head | tail], valid?), do: valid?.(head) and list_of?(tail, valid?)
  defp list_of?(_value, _valid?), do: false

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
