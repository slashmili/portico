defmodule Portico.Subscription do
  @moduledoc """
  Sends notifications from a server's `handle_info/2` subscription callback.

  Each subscription has its own callback process. `send/1` uses that process's
  active subscription, so application state does not need to hold a transport
  context. Calls from other processes, including spawned tasks and
  `handle_subscribe/2` before acknowledgement, return an error tuple.
  """

  @doc """
  Sends `{:resource_updated, uri}` through the current subscription.

      def handle_info({:status_changed, uri}, state) do
        :ok = Portico.Subscription.send({:resource_updated, uri})
        {:noreply, state}
      end

  Waits for the transport to handle the update, providing backpressure. Returns
  `:ok` on success. Valid updates outside the accepted URI filter are ignored and
  also return `:ok`, allowing application topics to cover multiple resources.

  Invalid messages return `{:error, :unsupported_message}`; invalid URIs return
  `{:error, :invalid_notification}`. Calls outside an active subscription callback
  process return `{:error, :not_subscription_worker}`. An unavailable transport
  returns `{:error, :closed}`. A rejected send does not itself end the subscription;
  the callback decides how to handle the error.
  """
  @spec send(term()) ::
          :ok
          | {:error,
             :unsupported_message | :invalid_notification | :not_subscription_worker | :closed}
  def send(message) do
    case Process.get({__MODULE__, :delivery}) do
      {owner, ref} -> deliver(owner, ref, message)
      nil -> {:error, :not_subscription_worker}
    end
  end

  defp deliver(owner, ref, {:resource_updated, uri} = message) do
    if Portico.Resource.valid_uri?(uri) do
      GenServer.call(owner, {ref, message}, :infinity)
    else
      {:error, :invalid_notification}
    end
  catch
    :exit, _reason -> {:error, :closed}
  end

  defp deliver(_owner, _ref, _message), do: {:error, :unsupported_message}

  @doc false

  def prepare(server, params, request) do
    if server.__portico__(:subscriptions) do
      case params do
        %{"notifications" => filter} when is_map(filter) ->
          uris = Map.get(filter, "resourceSubscriptions", [])
          flags = ["toolsListChanged", "promptsListChanged", "resourcesListChanged"]

          if is_list(uris) and Enum.all?(uris, &Portico.Resource.valid_uri?/1) and
               Enum.all?(flags, &(not Map.has_key?(filter, &1) or is_boolean(filter[&1]))) do
            {:ok,
             %{
               server: server,
               request: %{request | server: server},
               filter: %{resource_subscriptions: Enum.uniq(uris)}
             }}
          else
            {:error, :invalid_params}
          end

        _ ->
          {:error, :invalid_params}
      end
    else
      {:error, :method_not_found}
    end
  end
end
