defmodule Portico.Stream do
  @moduledoc """
  Context passed to a tool's `handle_stream/2` callback.

  `request` contains the validated request and application assigns. Use
  `send/2` inside the callback to report work, then return `{:ok, result}`.
  The remaining fields are internal; do not construct or retain this context.
  It is valid only in the task running the callback, for that invocation.
  """

  @enforce_keys [:request, :owner, :worker, :ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request: Portico.Request.t(),
          owner: pid(),
          worker: pid(),
          ref: reference()
        }

  @doc """
  Sends a progress message from the streaming callback.

  Accepts `{:progress, value}` or `{:progress, value, options}`, with optional
  numeric `:total` and UTF-8 `:message` options:

      Portico.Stream.send(stream, {:progress, 1})
      Portico.Stream.send(stream, {:progress, 2, total: 3, message: "Working"})

  Unlike `Kernel.send/2`, this function waits for the update to be handled.

  Values must strictly increase within the invocation. Returns `:ok` after the
  update is handled; this applies backpressure instead of queuing updates.
  Without a client progress token, updates are checked but not sent.
  Rejected updates return `{:error, reason}` and are not emitted. Reasons are
  `:unsupported_message`, `:invalid_progress`, `:invalid_options`, `:invalid_total`,
  `:invalid_message`, and `:non_increasing_progress`. An invalid context returns
  `:invalid_stream`; use outside the callback returns `:not_stream_worker`;
  an unavailable request process returns `:closed`.

  A rejected update does not end the stream or advance its progress. Handle the
  tuple in the callback, then continue or return a completed tool error.
  Call only from `handle_stream/2`.
  """
  @type error_reason ::
          :unsupported_message
          | :invalid_progress
          | :invalid_options
          | :invalid_total
          | :invalid_message
          | :non_increasing_progress
          | :invalid_stream
          | :not_stream_worker
          | :closed

  @spec send(t(), term()) :: :ok | {:error, error_reason()}
  def send(%__MODULE__{} = stream, {:progress, value}), do: progress(stream, value, [])

  def send(%__MODULE__{} = stream, {:progress, value, options}),
    do: progress(stream, value, options)

  def send(%__MODULE__{}, _message), do: {:error, :unsupported_message}
  def send(_stream, _message), do: {:error, :invalid_stream}

  defp progress(stream, value, options) do
    cond do
      self() != stream.worker ->
        {:error, :not_stream_worker}

      not is_number(value) ->
        {:error, :invalid_progress}

      not valid_options?(options) ->
        {:error, :invalid_options}

      Keyword.has_key?(options, :total) and not is_number(options[:total]) ->
        {:error, :invalid_total}

      Keyword.has_key?(options, :message) and
          not (is_binary(options[:message]) and String.valid?(options[:message])) ->
        {:error, :invalid_message}

      true ->
        update = options |> Map.new() |> Map.put(:progress, value)
        deliver(stream, update)
    end
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and Enum.all?(options, fn {key, _} -> key in [:total, :message] end)
  end

  defp deliver(stream, update) do
    GenServer.call(stream.owner, {stream.ref, :progress, update}, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end
end
