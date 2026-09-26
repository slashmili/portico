defmodule Portico.Protocol.Sampling do
  @moduledoc false

  def input_request(input) do
    %{
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => input.message}}
        ],
        "maxTokens" => input.max_tokens,
        "includeContext" => "none"
      }
    }
  end

  def decode(%{"role" => role, "model" => model, "content" => content} = answer) do
    with true <- role in ["user", "assistant"] and string?(model),
         true <- not Map.has_key?(answer, "stopReason") or string?(answer["stopReason"]),
         {:ok, text} <- text(content) do
      result = %{text: text, model: model}

      result =
        if Map.has_key?(answer, "stopReason"),
          do: Map.put(result, :stop_reason, answer["stopReason"]),
          else: result

      {:ok, {:sample, result}}
    else
      _ -> {:error, :invalid_params}
    end
  end

  def decode(_), do: {:error, :invalid_params}

  defp text([content]), do: text_block(content)
  defp text(content), do: text_block(content)

  defp text_block(%{"type" => "text", "text" => text}) do
    if string?(text), do: {:ok, text}, else: {:error, :invalid_params}
  end

  defp text_block(_), do: {:error, :invalid_params}
  defp string?(value), do: is_binary(value) and String.valid?(value)
end
