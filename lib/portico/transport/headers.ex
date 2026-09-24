defmodule Portico.Transport.Headers do
  @moduledoc false

  @doc """
  Matches standard MCP HTTP headers against a validated request body.

  Call after envelope and required metadata validation. Header names are
  case-insensitive; values are case-sensitive. Each applicable standard header
  must occur exactly once. Mcp-Name supports the specification's Base64 sentinel
  encoding, decoded exactly once before comparison.

  This checks protocol version, method, and the name/URI for named operations.
  It does not check Origin, content negotiation, notifications, or custom
  Mcp-Param headers. The HTTP boundary will map failures to status 400.
  """
  @spec validate([{String.t(), String.t()}], map()) :: :ok | {:error, :header_mismatch}
  def validate(headers, request) do
    version = get_in(request, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])
    method = request["method"]

    valid =
      matches?(headers, "mcp-protocol-version", version, :plain) and
        matches?(headers, "mcp-method", method, :plain) and
        name_matches?(headers, request)

    if valid, do: :ok, else: {:error, :header_mismatch}
  end

  defp name_matches?(headers, %{"method" => method, "params" => params})
       when method in ["tools/call", "prompts/get"] do
    matches?(headers, "mcp-name", params["name"], :encoded)
  end

  defp name_matches?(headers, %{"method" => "resources/read", "params" => params}) do
    matches?(headers, "mcp-name", params["uri"], :encoded)
  end

  defp name_matches?(_headers, _request), do: true

  defp matches?(headers, name, expected, encoding) do
    case for {key, value} <- headers, String.downcase(key) == name, do: value do
      [value] ->
        with true <- plain?(value), {:ok, decoded} <- decode(value, encoding) do
          decoded == expected
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp plain?(value) do
    String.trim(value) == value and Regex.match?(~r/\A[\x09\x20-\x7e]*\z/, value)
  end

  defp decode("=?base64?" <> rest = value, :encoded) do
    if String.ends_with?(rest, "?=") do
      encoded = binary_part(rest, 0, byte_size(rest) - 2)

      with {:ok, decoded} <- Base.decode64(encoded), true <- String.valid?(decoded) do
        {:ok, decoded}
      else
        _ -> :error
      end
    else
      {:ok, value}
    end
  end

  defp decode(value, _encoding), do: {:ok, value}
end
