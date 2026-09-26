defmodule Portico.Result do
  @moduledoc """
  A tool's completed result, returned by application callbacks.

  Constructors return `{:ok, result}` or `{:error, reason}`. Content uses
  atom-keyed maps; protocol encoding is separate. Match the constructor's success
  tuple explicitly, then return `{:ok, result}` from `call/2` or `handle_stream/2`:

      def call(_arguments, _request) do
        {:ok, result} = Portico.Result.text("Finished")
        {:ok, result}
      end

  This match asserts successful construction; it raises `MatchError` on an error
  tuple. Use `case` when construction failures need recovery.

  `error/1` constructs a completed tool failure (`is_error: true`); successfully
  building it still returns `{:ok, result}`. A constructor error means no result
  was built. `text/2` and `put_error/2` accept structs or constructor tuples,
  propagating an existing error so pipelines preserve the first failure.
  """

  defstruct content: [], is_error: false, structured_content: :not_set

  @type text_content :: %{type: String.t(), text: String.t()}
  @type t :: %__MODULE__{
          content: [text_content()],
          is_error: boolean(),
          structured_content: term()
        }
  @type error_reason ::
          :invalid_text | :invalid_result | :invalid_error_flag | :invalid_structured_content
  @type outcome :: {:ok, t()} | {:error, error_reason()}

  @doc """
  Builds structured content with a serialized JSON text fallback.

  Accepts any JSON value, including arrays, scalars and `nil` (JSON null).
  Plain maps may have atom or UTF-8 string keys; keys normalize recursively to
  strings. Colliding keys, structs, non-JSON values and invalid UTF-8 return
  `{:error, :invalid_structured_content}`. Other atom values are not JSON strings.

  The returned `structured_content` contains normalized data. Ordinary text
  results use `:not_set` to omit the wire field, distinct from explicit JSON null.
  `text/2` appends commentary and `put_error/2` changes the error flag while
  preserving structured content. A tool may declare `:output_schema` with
  `Portico.Tool`; successful completed results are checked against it by Portico,
  rather than by this constructor.

  ## Examples

      iex> {:ok, result} = Portico.Result.structured(%{sum: 5})
      iex> result.structured_content
      %{"sum" => 5}
  """
  @spec structured(term()) :: outcome()
  def structured(value) do
    with {:ok, normalized} <- normalize_json(value),
         {:ok, json} <- Portico.Protocol.Encoder.json(normalized) do
      {:ok,
       %__MODULE__{
         structured_content: normalized,
         content: [%{type: "text", text: json}]
       }}
    else
      _ -> {:error, :invalid_structured_content}
    end
  end

  defp normalize_json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      with true <- is_binary(key) and String.valid?(key) and not Map.has_key?(acc, key),
           {:ok, normalized} <- normalize_json(value) do
        {:cont, {:ok, Map.put(acc, key, normalized)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize_json([]), do: {:ok, []}

  defp normalize_json([head | tail]) do
    with {:ok, head} <- normalize_json(head),
         true <- is_list(tail),
         {:ok, tail} <- normalize_json(tail) do
      {:ok, [head | tail]}
    else
      _ -> :error
    end
  end

  defp normalize_json(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp normalize_json(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp normalize_json(_), do: :error

  @doc """
  Builds one text item. Accepts UTF-8 strings, including empty strings.
  Invalid types or encoding return `{:error, :invalid_text}`.

  ## Examples

      iex> Portico.Result.text("5")
      {:ok, %Portico.Result{content: [%{type: "text", text: "5"}]}}
  """
  @spec text(String.t()) :: outcome()
  def text(text), do: text(%__MODULE__{}, text)

  @doc """
  Appends text, preserving content order and the error flag.

  Accepts a Result struct or an `{:ok, result}` tuple. Existing errors pass
  through unchanged. Invalid containers return `{:error, :invalid_result}`;
  invalid new text returns `{:error, :invalid_text}`. Existing content items
  are checked by the protocol encoder when the callback returns.

  ## Examples

      iex> {:ok, result} = Portico.Result.text("First") |> Portico.Result.text("Second")
      iex> result.content
      [%{type: "text", text: "First"}, %{type: "text", text: "Second"}]
  """
  @spec text(t() | outcome(), String.t()) :: outcome()
  def text({:error, _} = error, _text), do: error
  def text({:ok, result}, text), do: text(result, text)

  def text(%__MODULE__{content: content, is_error: flag} = result, text)
      when is_list(content) and is_boolean(flag) do
    if is_binary(text) and String.valid?(text),
      do: {:ok, %{result | content: content ++ [%{type: "text", text: text}]}},
      else: {:error, :invalid_text}
  end

  def text(_result, _text), do: {:error, :invalid_result}

  @doc """
  Builds a completed tool error with one UTF-8 text item.

  Returns `{:ok, result}` with `is_error: true`, suitable as a callback return.
  Invalid text returns `{:error, :invalid_text}`. Over HTTP, a completed tool
  error uses `isError: true` inside a completed result rather than a JSON-RPC error.

  ## Examples

      iex> {:ok, result} = Portico.Result.error("Choose a date in the future.")
      iex> result.is_error
      true
  """
  @spec error(String.t()) :: outcome()
  def error(message), do: message |> text() |> put_error(true)

  @doc """
  Sets or clears the tool error flag without changing content.

  Accepts a struct or constructor tuple and returns `{:ok, result}`. Existing
  errors pass through unchanged. A non-boolean flag returns
  `{:error, :invalid_error_flag}`; invalid containers return `{:error, :invalid_result}`.

  ## Examples

      iex> {:ok, result} = Portico.Result.text("Try another value.") |> Portico.Result.put_error(true)
      iex> result.is_error
      true
      iex> {:ok, result} = Portico.Result.put_error(result, false)
      iex> result.is_error
      false
  """
  @spec put_error(t() | outcome(), boolean()) :: outcome()
  def put_error({:error, _} = error, _flag), do: error
  def put_error({:ok, result}, flag), do: put_error(result, flag)

  def put_error(%__MODULE__{content: content} = result, flag) when is_list(content) do
    if is_boolean(flag),
      do: {:ok, %{result | is_error: flag}},
      else: {:error, :invalid_error_flag}
  end

  def put_error(_result, _flag), do: {:error, :invalid_result}
end
