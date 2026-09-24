defmodule Portico.Result do
  @moduledoc """
  A tool's completed result, returned by application callbacks.

  Content items use atom-keyed Elixir maps. Protocol encoding is a separate
  responsibility; this struct is not a JSON-RPC response.

  Currently only text content is supported. Use `text/1` for success and
  `error/1` for an expected tool failure with a client-facing explanation.
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
    unless String.valid?(text) do
      raise ArgumentError, "expected text to be a valid UTF-8 string"
    end

    %__MODULE__{content: [%{type: "text", text: text}]}
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
    %{text(message) | is_error: true}
  end
end
