defmodule Portico.Result do
  @moduledoc """
  A tool's completed result, returned by application callbacks.

  Content items use atom-keyed Elixir maps. Protocol encoding is a separate
  responsibility; this struct is not a JSON-RPC response.

  Currently only text content is supported. Prefer `text/1` to construct a
  validated text result.
  """

  defstruct content: []

  @type text_content :: %{type: String.t(), text: String.t()}
  @type t :: %__MODULE__{content: [text_content()]}

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
end
