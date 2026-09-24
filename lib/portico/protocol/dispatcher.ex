defmodule Portico.Protocol.Dispatcher do
  @moduledoc false

  alias Portico.{Request, Result, Server}
  alias Portico.Protocol.{Error, Validation}

  @doc """
  Processes a decoded protocol message through the current validation stages.

  Returns a JSON-ready reply or `:no_response` for a valid notification.
  Envelope errors take precedence over request metadata errors. Notifications
  are ignored; no notification handlers are implemented yet.

  No protocol request methods are implemented at this stage, so structurally
  valid requests return Method not found. Version support checks and successful
  method dispatch will be added before this becomes a complete MCP entry point.
  Direct `call_tool/4` remains available for application tests.
  """
  @spec dispatch(module(), term()) :: {:reply, map()} | :no_response
  def dispatch(_server, message) do
    case Validation.envelope(message) do
      {:error, :invalid_request} ->
        {:reply, Error.response(:invalid_request, readable_id(message))}

      {:ok, :notification, _notification} ->
        :no_response

      {:ok, :request, request} ->
        case Validation.request_metadata(Map.get(request, "params", %{})) do
          {:error, :invalid_params} ->
            {:reply, Error.response(:invalid_params, request["id"])}

          {:ok, _metadata} ->
            {:reply, Error.response(:method_not_found, request["id"])}
        end
    end
  end

  defp readable_id(%{"id" => id}) when is_integer(id), do: id

  defp readable_id(%{"id" => id}) when is_binary(id) do
    if String.valid?(id), do: id, else: nil
  end

  defp readable_id(_message), do: nil

  @spec call_tool(module(), String.t(), map(), Request.t()) ::
          {:reply, Result.t(), Request.t()} | {:error, :unknown_tool}
  def call_tool(server, name, arguments, %Request{} = request) when is_binary(name) do
    unless is_map(arguments) and not is_struct(arguments) do
      raise ArgumentError, "expected tool arguments to be a plain map"
    end

    case Enum.find(Server.tools(server), &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      %{module: module} ->
        case module.call(arguments, request) do
          {:reply, %Result{}, %Request{}} = reply ->
            reply

          _other ->
            raise ArgumentError,
                  "invalid return from #{inspect(module)}.call/2; " <>
                    "expected {:reply, %Portico.Result{}, %Portico.Request{}}"
        end
    end
  end
end
