defmodule Portico.Protocol.Encoder do
  @moduledoc false

  alias Portico.Result

  @doc "Encodes supported text results, rejecting malformed or unsupported content."
  @spec tool_result(Result.t()) :: {:ok, map()} | {:error, :invalid_result}
  def tool_result(%Result{content: content}) do
    with {:ok, encoded} <- text_content(content) do
      {:ok, %{"content" => encoded, "isError" => false}}
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
