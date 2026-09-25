defmodule Portico.Protocol.Elicitation do
  @moduledoc false
  alias Portico.Input

  def supported?(request) do
    case request.client_capabilities["elicitation"] do
      value when is_map(value) and map_size(value) == 0 -> true
      %{"form" => form} when is_map(form) -> true
      _ -> false
    end
  end

  def encode(%Input{} = form, state, request) do
    with {:ok, form} <- Input.form(form.message, schema: form.schema) do
      cond do
        not string?(state) ->
          {:error, :invalid_request_state}

        not supported?(request) ->
          {:error, :form_not_supported}

        true ->
          with {:ok, token} <- Portico.Elicitation.seal(form, state, request) do
            {:ok, form,
             %{
               "resultType" => "input_required",
               "requestState" => token,
               "inputRequests" => %{
                 "form" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "mode" => "form",
                     "message" => form.message,
                     "requestedSchema" => form.schema
                   }
                 }
               }
             }}
          end
      end
    end
  end

  def retry(params) do
    case {Map.fetch(params, "requestState"), Map.fetch(params, "inputResponses")} do
      {:error, :error} ->
        :initial

      {{:ok, state}, responses} ->
        if string?(state), do: answer(responses, state), else: {:error, :invalid_params}

      _ ->
        {:error, :invalid_params}
    end
  end

  defp answer(:error, state), do: {:resume, :missing, state}

  defp answer({:ok, responses}, state) do
    if object?(responses) do
      case Map.fetch(responses, "form") do
        :error -> {:resume, :missing, state}
        {:ok, reply} -> decode(reply, state)
      end
    else
      {:error, :invalid_params}
    end
  end

  defp decode(%{"action" => action} = reply, state) do
    content = Map.get(reply, "content", %{})

    if object?(reply) and object?(content) and Enum.all?(content, fn {_, v} -> primitive?(v) end) do
      case action do
        "accept" -> {:resume, {:accept, content}, state}
        "decline" -> {:resume, :decline, state}
        "cancel" -> {:resume, :cancel, state}
        _ -> {:error, :invalid_params}
      end
    else
      {:error, :invalid_params}
    end
  end

  defp decode(_reply, _state), do: {:error, :invalid_params}
  defp primitive?(v), do: string?(v) or is_number(v) or is_boolean(v)
  defp object?(v), do: is_map(v) and not is_struct(v) and Enum.all?(Map.keys(v), &string?/1)
  defp string?(v), do: is_binary(v) and String.valid?(v)
end
