defmodule Portico.Protocol.Resources do
  @moduledoc false
  alias Portico.{Resource, Server}

  def metadata(resource) do
    %{"uri" => resource.uri, "name" => resource.name}
    |> optional("description", resource[:description])
    |> optional("mimeType", resource[:mime_type])
  end

  def read(server, params, request) do
    uri = params["uri"]

    cond do
      not Resource.valid_uri?(uri) ->
        {:error, :invalid_params}

      Map.has_key?(params, "requestState") or Map.has_key?(params, "inputResponses") ->
        {:error, :invalid_params}

      true ->
        case Enum.find(Server.resources(server), &(&1.uri == uri)) do
          nil -> {:error, :resource_not_found}
          resource -> invoke(resource, %{request | server: server, resource_uri: uri})
        end
    end
  end

  defp invoke(resource, request) do
    case resource.module.read(request) do
      {:ok, %Resource{text: text}} ->
        case Resource.text(text) do
          {:ok, content} ->
            content = %{content | uri: resource.uri, mime_type: resource[:mime_type]}

            fields =
              %{"uri" => content.uri, "text" => content.text}
              |> optional("mimeType", content.mime_type)

            {:ok, content, %{"contents" => [fields], "cacheScope" => "private", "ttlMs" => 0}}

          {:error, _} ->
            {:error, :invalid_resource}
        end

      {:error, reason} ->
        {:callback_error, reason}

      _ ->
        {:error, :invalid_callback_return}
    end
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
