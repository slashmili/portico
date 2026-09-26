defmodule Portico.Protocol.Completion do
  @moduledoc false
  alias Portico.Server

  def supported?(server) do
    Enum.any?(
      Server.prompts(server) ++ Server.resource_templates(server),
      &callback?(&1.module)
    )
  end

  def complete(server, params, request) do
    if supported?(server), do: execute(server, params, request), else: {:error, :method_not_found}
  end

  defp callback?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :complete, 3)

  defp execute(server, params, request) do
    context = Map.get(params, "context", %{})

    with true <- object?(params["ref"]),
         true <- object?(params["argument"]),
         %{"name" => name, "value" => value} <- params["argument"],
         true <- string?(name) and string?(value),
         true <- object?(context),
         arguments = Map.get(context, "arguments", %{}),
         true <- object?(arguments) and Enum.all?(Map.values(arguments), &string?/1),
         {:ok, module, names, request} <- resolve(server, params["ref"], request),
         true <- name in names and Enum.all?(Map.keys(arguments), &(&1 in names)) do
      request = %{request | server: server, arguments: arguments}

      outcome =
        if callback?(module),
          do: module.complete(name, value, request),
          else: {:ok, []}

      encode(outcome)
    else
      _ -> {:error, :invalid_params}
    end
  end

  defp resolve(server, %{"type" => "ref/prompt", "name" => name}, request) do
    case Enum.find(Server.prompts(server), &(&1.name == name)) do
      nil ->
        :error

      prompt ->
        {:ok, prompt.module, Enum.map(prompt.arguments, & &1.name),
         %{request | prompt_name: name}}
    end
  end

  defp resolve(server, %{"type" => "ref/resource", "uri" => uri}, request) do
    case Enum.find(Server.resource_templates(server), &(&1.uri_template == uri)) do
      nil ->
        :error

      resource ->
        {:ok, resource.module, resource.matcher.names,
         %{request | resource_uri: uri, resource_route: {resource.module, uri}}}
    end
  end

  defp resolve(_, _, _), do: :error

  defp encode({:ok, values}) do
    if strings?(values) do
      total = length(values)
      completion = %{values: Enum.take(values, 100), total: total, has_more: total > 100}

      {:ok, completion,
       %{
         "completion" => %{
           "values" => completion.values,
           "total" => total,
           "hasMore" => completion.has_more
         }
       }}
    else
      {:error, :invalid_completion}
    end
  end

  defp encode({:error, reason}), do: {:callback_error, reason}
  defp encode(_), do: {:error, :invalid_callback_return}

  defp strings?([]), do: true
  defp strings?([head | tail]), do: string?(head) and strings?(tail)
  defp strings?(_), do: false

  defp object?(value),
    do: is_map(value) and not is_struct(value) and Enum.all?(Map.keys(value), &string?/1)

  defp string?(value), do: is_binary(value) and String.valid?(value)
end
