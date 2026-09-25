defmodule Portico.Protocol.Encoder do
  @moduledoc false

  alias Portico.Result
  alias Portico.Protocol.Error

  @doc "Encodes JSON, returning a stable error without exposing the rejected value."
  @spec json(term()) :: {:ok, String.t()} | {:error, :invalid_json}
  def json(value) do
    {:ok, JSON.encode!(value)}
  rescue
    _error -> {:error, :invalid_json}
  end

  @doc false
  def internal_error(id) do
    case Error.response(:internal_error, id) do
      {:error, :invalid_id} -> Error.response(:internal_error)
      response -> response
    end
  end

  @doc "Encodes supported text results, rejecting malformed or unsupported content."
  @spec tool_result(Result.t()) :: {:ok, map()} | {:error, :invalid_result}
  def tool_result(%Result{content: content, is_error: is_error}) when is_boolean(is_error) do
    with {:ok, encoded} <- text_content(content) do
      {:ok, %{"content" => encoded, "isError" => is_error}}
    end
  end

  def tool_result(_result), do: {:error, :invalid_result}

  defp text_content([]), do: {:ok, []}

  defp text_content([%{type: "text", text: text} = item | rest])
       when map_size(item) == 2 and is_binary(text) do
    if String.valid?(text) do
      with {:ok, encoded_rest} <- text_content(rest) do
        {:ok, [%{"type" => "text", "text" => text} | encoded_rest]}
      end
    else
      {:error, :invalid_result}
    end
  end

  defp text_content(_content), do: {:error, :invalid_result}
end
