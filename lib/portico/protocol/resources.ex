defmodule Portico.Protocol.Resources do
  @moduledoc false
  alias Portico.{Input, Resource, Server}
  alias Portico.Protocol.{Dispatcher, Elicitation}

  def metadata(resource) do
    {key, uri} =
      if Map.has_key?(resource, :uri),
        do: {"uri", resource.uri},
        else: {"uriTemplate", resource.uri_template}

    %{key => uri, "name" => resource.name}
    |> optional("description", resource[:description])
    |> optional("mimeType", resource[:mime_type])
  end

  def read(server, params, request) do
    uri = params["uri"]

    cond do
      not Resource.valid_uri?(uri) ->
        {:error, :invalid_params}

      true ->
        case Enum.find(Server.resources(server), &(&1.uri == uri)) do
          nil ->
            read_template(server, uri, request, Elicitation.retry(params))

          resource ->
            invoke(
              resource,
              %{request | server: server, resource_uri: uri},
              Elicitation.retry(params)
            )
        end
    end
  end

  defp read_template(server, uri, request, retry) do
    matches =
      for resource <- Server.resource_templates(server),
          {:ok, params} <- [Portico.Resource.Template.match(resource.matcher, uri)],
          do: {resource, params}

    case matches do
      [] ->
        {:error, :resource_not_found}

      [{resource, params}] ->
        invoke(
          resource,
          %{request | server: server, resource_uri: uri, resource_params: params},
          retry
        )

      _ ->
        {:error, :ambiguous_resource}
    end
  end

  defp invoke(_resource, _request, {:error, _} = error), do: error

  defp invoke(resource, request, retry) do
    route = Map.get(resource, :uri, resource[:uri_template])
    request = %{request | resource_route: {resource.module, route}}

    outcome =
      case retry do
        :initial ->
          resource.module.read(request)

        {:resume, answer, token} ->
          if function_exported?(resource.module, :handle_input, 3),
            do: Elicitation.resume(resource.module, answer, token, request, [:form]),
            else: {:input_error, :invalid_params}
      end

    case outcome do
      {:ok, %Input{mode: :form} = form, state} ->
        if function_exported?(resource.module, :handle_input, 3),
          do: Dispatcher.input_result(form, state, request),
          else: {:error, :missing_input_callback}

      {:input_error, _} = error ->
        error

      {:ok, %Resource{} = value} ->
        case encode_content(value) do
          {:ok, content, payload} ->
            content = %{content | uri: request.resource_uri, mime_type: resource[:mime_type]}

            fields =
              Map.put(payload, "uri", content.uri)
              |> optional("mimeType", content.mime_type)

            {:ok, content, %{"contents" => [fields], "cacheScope" => "private", "ttlMs" => 0}}

          {:error, _} ->
            {:error, :invalid_resource}
        end

      {:ok, values} when is_list(values) ->
        encode_contents(values)

      {:error, :resource_not_found} ->
        {:error, :resource_not_found}

      {:error, reason} ->
        {:callback_error, reason}

      _ ->
        {:error, :invalid_callback_return}
    end
  end

  defp encode_contents(values) do
    Enum.reduce_while(values, {:ok, [], []}, fn
      %Resource{} = value, {:ok, contents, fields} ->
        options = [uri: value.uri]

        options =
          if is_nil(value.mime_type), do: options, else: options ++ [mime_type: value.mime_type]

        case encode_content(value, options) do
          {:ok, content, payload} ->
            field =
              payload |> Map.put("uri", content.uri) |> optional("mimeType", content.mime_type)

            {:cont, {:ok, [content | contents], [field | fields]}}

          _ ->
            {:halt, {:error, :invalid_resource}}
        end

      _, _ ->
        {:halt, {:error, :invalid_resource}}
    end)
    |> case do
      {:ok, contents, fields} ->
        {:ok, Enum.reverse(contents),
         %{"contents" => Enum.reverse(fields), "cacheScope" => "private", "ttlMs" => 0}}

      error ->
        error
    end
  end

  defp encode_content(value, options \\ [])

  defp encode_content(%Resource{text: text, blob: nil}, options) when is_binary(text) do
    with {:ok, content} <- Resource.text(text, options),
         do: {:ok, content, %{"text" => text}}
  end

  defp encode_content(%Resource{text: nil, blob: blob}, options) when is_binary(blob) do
    with {:ok, content} <- Resource.blob(blob, options),
         do: {:ok, content, %{"blob" => Base.encode64(blob)}}
  end

  defp encode_content(_, _), do: {:error, :invalid_resource}

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
