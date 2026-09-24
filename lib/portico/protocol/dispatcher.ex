defmodule Portico.Protocol.Dispatcher do
  @moduledoc false

  alias Portico.{Request, Result, Server}

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
