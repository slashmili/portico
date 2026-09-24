defmodule Portico.Result do
  @moduledoc """
  A tool's completed result, returned by application callbacks.

  Content items use atom-keyed Elixir maps. Protocol encoding is a separate
  responsibility; this struct is not a JSON-RPC response.

  Currently only text content is supported. Use `text/1` for success and
  `error/1` for an expected tool failure with a client-facing explanation.
  Build results incrementally with `text/2` and `put_error/2`.
  """

  defstruct content: [], is_error: false

  @type text_content :: %{type: String.t(), text: String.t()}
  @type t :: %__MODULE__{content: [text_content()], is_error: boolean()}

  @doc """
  Builds a result containing one text item.

  Accepts a UTF-8 string, including an empty string, and preserves it unchanged.
  Raises `ArgumentError` for invalid UTF-8 and `FunctionClauseError` for
  non-binary values. Values are not automatically converted to strings.

  ## Examples

      iex> Portico.Result.text("5")
      %Portico.Result{content: [%{type: "text", text: "5"}]}
  """
  @spec text(String.t()) :: t()
  def text(text) when is_binary(text) do
    text(%__MODULE__{}, text)
  end

  @doc """
  Appends a UTF-8 text item, preserving existing content and the error flag.

  Accepts the same text values as `text/1`. Returns a new result; the original
  is unchanged. Existing content is preserved and checked by the encoder when
  the callback returns.

  ## Examples

      iex> result = %Portico.Result{} |> Portico.Result.text("First") |> Portico.Result.text("Second")
      iex> result.content
      [%{type: "text", text: "First"}, %{type: "text", text: "Second"}]
  """
  @spec text(t(), String.t()) :: t()
  def text(%__MODULE__{content: content} = result, text)
      when is_binary(text) and is_list(content) do
    unless String.valid?(text) do
      raise ArgumentError, "expected text to be a valid UTF-8 string"
    end

    %{result | content: content ++ [%{type: "text", text: text}]}
  end

  @doc """
  Builds a completed tool error containing one UTF-8 text item.

  Return it through the usual `{:ok, result}` callback. The client
  receives `isError: true` in a completed result (HTTP 200), rather than a
  JSON-RPC protocol error. Use a message the client can act on; unexpected
  callback exceptions still become sanitized protocol errors.

  Accepts the same text values as `text/1`, including an empty string.

  ## Examples

      iex> result = Portico.Result.error("Choose a date in the future.")
      iex> result.is_error
      true
  """
  @spec error(String.t()) :: t()
  def error(message) when is_binary(message) do
    message |> text() |> put_error(true)
  end

  @doc """
  Sets or clears the tool error flag without changing content.

  Accepts only a boolean. Both success and error results are returned from
  callbacks as `{:ok, result}`.

  ## Examples

      iex> result = Portico.Result.text("Try another value.") |> Portico.Result.put_error(true)
      iex> result.is_error
      true
      iex> Portico.Result.put_error(result, false).is_error
      false
  """
  @spec put_error(t(), boolean()) :: t()
  def put_error(%__MODULE__{} = result, is_error) when is_boolean(is_error) do
    %{result | is_error: is_error}
  end
end
