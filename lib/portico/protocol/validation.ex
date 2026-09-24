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
