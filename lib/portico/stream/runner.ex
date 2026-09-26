defmodule Portico.Stream.Runner do
  @moduledoc false
  alias Portico.{Input, Result, Stream}
  alias Portico.Protocol.{Dispatcher, Encoder}

  # The owner retains the transport; only application work runs in the linked
  # task. Catch callback failures so they cannot tear down the response process.
  # A killed owner kills its task. The after block covers normal returns/errors.
  def run(execution, acc, emit, timeout) do
    owner = self()
    ref = make_ref()
    metadata = Logger.metadata()

    task =
      Task.async(fn ->
        Logger.metadata(metadata)
        stream = %Stream{request: execution.request, owner: owner, worker: self(), ref: ref}

        try do
          case execution.module.handle_stream(execution.data, stream) do
            {:ok, %Result{} = result} ->
              case Encoder.tool_result(result, execution.module.__portico_output_validator__()) do
                {:ok, _} -> {:ok, result}
                {:error, _reason} = error -> error
              end

            {:ok, %Input{} = form, state} ->
              if function_exported?(execution.module, :handle_input, 3) do
                Dispatcher.input_result(form, state, execution.request)
              else
                {:error, :missing_input_callback}
              end

            {:error, _reason} = error ->
              error

            _ ->
              {:error, :invalid_callback_return}
          end
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
        end
      end)

    now = System.monotonic_time(:millisecond)

    state = %{
      task: task,
      ref: ref,
      token: execution.request.progress_token,
      last: nil,
      deadline: now + timeout,
      tick: now + 1_000,
      emit: emit
    }

    try do
      loop(state, acc)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp loop(state, acc) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= state.deadline ->
        {:error, :timeout, acc}

      now >= state.tick ->
        case state.emit.(:heartbeat, acc) do
          {:ok, acc} -> loop(%{state | tick: now + 1_000}, acc)
          {:error, acc} -> {:closed, acc}
        end

      true ->
        receive_event(state, acc, min(state.deadline, state.tick) - now)
    end
  end

  defp receive_event(%{task: task, ref: ref} = state, acc, wait) do
    task_ref = task.ref
    worker = task.pid

    receive do
      {:"$gen_call", {^worker, _tag} = from, {^ref, :progress, progress}} ->
        if is_nil(state.last) or progress.progress > state.last do
          case emit_progress(state, progress, acc) do
            {:ok, acc} ->
              GenServer.reply(from, :ok)
              loop(%{state | last: progress.progress}, acc)

            {:error, acc} ->
              {:closed, acc}
          end
        else
          GenServer.reply(from, {:error, :non_increasing_progress})
          loop(state, acc)
        end

      {^task_ref, {:ok, result}} ->
        Process.demonitor(task_ref, [:flush])
        {:ok, result, acc}

      {^task_ref, {:input, form, state, fields}} ->
        Process.demonitor(task_ref, [:flush])
        {:input, form, state, fields, acc}

      {^task_ref, {:input_error, reason}} ->
        Process.demonitor(task_ref, [:flush])
        {:input_error, reason, acc}

      {^task_ref, {:error, reason}} ->
        Process.demonitor(task_ref, [:flush])
        {:error, reason, acc}

      {^task_ref, {:failed, kind, reason, stack}} ->
        Process.demonitor(task_ref, [:flush])
        {:failed, kind, reason, stack, acc}

      {:DOWN, ^task_ref, :process, ^worker, _reason} ->
        {:error, :worker_stopped, acc}
    after
      wait -> loop(state, acc)
    end
  end

  defp emit_progress(%{token: nil}, _progress, acc), do: {:ok, acc}
  defp emit_progress(state, progress, acc), do: state.emit.({:progress, progress}, acc)
end
