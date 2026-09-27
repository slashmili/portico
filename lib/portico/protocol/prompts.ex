defmodule Portico.Protocol.Prompts do
  @moduledoc false
  alias Portico.{Prompt, Server}

  def metadata(prompt) do
    %{
      "name" => prompt.name,
      "arguments" =>
        Enum.map(prompt.arguments, fn argument ->
          %{"name" => argument.name, "required" => argument.required}
          |> optional("description", argument[:description])
        end)
    }
    |> optional("description", prompt[:description])
  end

  def get(server, params, request) do
    name = params["name"]
    arguments = Map.get(params, "arguments", %{})

    with true <- string?(name) and name != "",
         true <- is_map(arguments) and not is_struct(arguments),
         true <- Enum.all?(arguments, fn {key, value} -> string?(key) and string?(value) end),
         false <- Map.has_key?(params, "requestState") or Map.has_key?(params, "inputResponses") do
      case Enum.find(Server.prompts(server), &(&1.name == name)) do
        nil ->
          {:error, :unknown_prompt}

        prompt ->
          names = Enum.map(prompt.arguments, & &1.name)

          if Enum.all?(Map.keys(arguments), &(&1 in names)) and
               Enum.all?(prompt.arguments, &(not &1.required or Map.has_key?(arguments, &1.name))) do
            invoke(prompt.module, arguments, %{
              request
              | server: server,
                prompt_name: name,
                arguments: arguments
            })
          else
            {:error, :invalid_params}
          end
      end
    else
      _ -> {:error, :invalid_params}
    end
  end

  defp invoke(module, arguments, request) do
    case module.get(arguments, request) do
      {:ok, %Prompt{} = prompt} ->
        with {:ok, result} <- Prompt.validate(prompt) do
          messages =
            Enum.map(result.messages, fn message ->
              %{
                "role" => message.role,
                "content" => %{"type" => "text", "text" => message.content.text}
              }
            end)

          {:ok, result, %{"messages" => messages}}
        end

      {:error, reason} ->
        {:callback_error, reason}

      _ ->
        {:error, :invalid_callback_return}
    end
  end

  defp string?(value), do: is_binary(value) and String.valid?(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
