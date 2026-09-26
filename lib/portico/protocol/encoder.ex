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

  @doc "Encodes supported text and structured results, rejecting malformed or unsupported content."
  @spec tool_result(Result.t()) :: {:ok, map()} | {:error, :invalid_result}
  def tool_result(%Result{content: content, is_error: is_error} = result)
      when is_boolean(is_error) do
    with {:ok, encoded} <- text_content(content) do
      structured_content(
        %{"content" => encoded, "isError" => is_error},
        result.structured_content
      )
    end
  end

  def tool_result(_result), do: {:error, :invalid_result}

  # Validate the normalized wire value, including manually constructed Results.
  def tool_result(result, validator) do
    with {:ok, fields} <- tool_result(result) do
      cond do
        is_nil(validator) or fields["isError"] ->
          {:ok, fields}

        Map.has_key?(fields, "structuredContent") and
            Portico.Schema.valid?(validator, fields["structuredContent"]) ->
          {:ok, fields}

        true ->
          {:error, :invalid_output}
      end
    end
  end

  defp structured_content(fields, :not_set), do: {:ok, fields}

  defp structured_content(fields, value) do
    case Result.structured(value) do
      {:ok, result} -> {:ok, Map.put(fields, "structuredContent", result.structured_content)}
      {:error, _} -> {:error, :invalid_result}
    end
  end

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
