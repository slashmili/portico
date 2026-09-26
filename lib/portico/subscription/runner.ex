defmodule Portico.Subscription.Runner do
  @moduledoc false

  def run(execution, acc, emit, timeout) do
    owner = self()
    ref = make_ref()
    metadata = Logger.metadata()

    task =
      Task.async(fn ->
        Logger.metadata(metadata)

        try do
          case execution.server.handle_subscribe(execution.filter, execution.request) do
            {:ok, accepted, state} ->
              with {:ok, uris} <- accepted_uris(accepted, execution.filter.resource_subscriptions) do
                :ok = GenServer.call(owner, {ref, {:ack, uris}}, :infinity)
                Process.put({Portico.Subscription, :delivery}, {owner, ref})
                callbacks(execution.server, state)
              end

            {:error, _} = error ->
              error

            _ ->
              {:error, :invalid_callback_return}
          end
        catch
          _kind, _reason -> {:error, :callback_failed}
        end
      end)

    now = System.monotonic_time(:millisecond)

    state = %{
      task: task,
      ref: ref,
      emit: emit,
      uris: [],
      deadline: if(timeout == :infinity, do: :infinity, else: now + timeout),
      tick: now + 1_000,
      acknowledged: false
    }

    try do
      loop(state, acc)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp accepted_uris(%{resource_subscriptions: uris} = filter, requested)
       when map_size(filter) == 1 and is_list(uris) do
    if Enum.all?(uris, &(&1 in requested)),
      do: {:ok, Enum.uniq(uris)},
      else: {:error, :invalid_subscription_filter}
  end

  defp accepted_uris(_, _), do: {:error, :invalid_subscription_filter}

  defp callbacks(server, state) do
    receive do
      message ->
        case server.handle_info(message, state) do
          {:noreply, state} ->
            callbacks(server, state)

          {:stop, :normal, _state} ->
            :ok

          {:error, _} = error ->
            error

          _ ->
            {:error, :invalid_callback_return}
        end
    end
  end

  defp loop(state, acc) do
    now = System.monotonic_time(:millisecond)

    cond do
      state.deadline != :infinity and now >= state.deadline ->
        if state.acknowledged, do: {:ok, acc}, else: {:error, :timeout, acc}

      now >= state.tick ->
        case state.emit.(:heartbeat, acc) do
          {:ok, acc} -> loop(%{state | tick: now + 1_000}, acc)
          {:error, acc} -> {:closed, acc}
        end

      true ->
        wait =
          if state.deadline == :infinity,
            do: state.tick - now,
            else: min(state.tick, state.deadline) - now

        receive_event(state, acc, wait)
    end
  end

  defp receive_event(%{task: task, ref: ref} = state, acc, wait) do
    worker = task.pid
    task_ref = task.ref

    receive do
      {:"$gen_call", {^worker, _} = from, {^ref, event}} ->
        outcome =
          case event do
            {:resource_updated, uri} ->
              if uri in state.uris, do: state.emit.(event, acc), else: {:ok, acc}

            _ ->
              state.emit.(event, acc)
          end

        case outcome do
          {:ok, acc} ->
            GenServer.reply(from, :ok)

            state =
              case event do
                {:ack, uris} -> %{state | uris: uris, acknowledged: true}
                _ -> state
              end

            loop(state, acc)

          {:error, acc} ->
            {:closed, acc}
        end

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])

        case result do
          :ok -> {:ok, acc}
          {:error, reason} -> {:error, reason, acc}
        end

      {:DOWN, ^task_ref, :process, ^worker, _} ->
        {:error, :worker_stopped, acc}
    after
      wait -> loop(state, acc)
    end
  end
end
