defmodule Portico.Prompt do
  @moduledoc ~S"""
  Declares a prompt and builds a single user-role text message.

      defmodule MyApp.Prompts.ReviewCode do
        use Portico.Prompt,
          description: "Prepare a code review request.",
          arguments: [code: [description: "Code to review", required: true]]

        def get(%{"code" => code}, _request) do
          {:ok, prompt} = Portico.Prompt.text("Review this code for bugs:\n\n#{code}")
          {:ok, prompt}
        end
      end

  Register with `prompt "review_code", MyApp.Prompts.ReviewCode` in your server.
  Arguments are a keyword list of names with optional `:description` and boolean
  `:required` (default false). Names become strings; incoming keys never become
  atoms. Invalid metadata, duplicate names, and missing get/2 fail compilation.

  `get/2` receives a string-keyed map of UTF-8 string values and a fresh
  `Portico.Request` with server, prompt_name, arguments and application assigns.
  Missing required or undeclared arguments fail before the callback runs.
  Optional absent arguments remain absent; empty strings are valid values.
  Prompts produce messages for the client; Portico does not call an LLM.

  Return `{:ok, prompt}` or `{:error, reason}`. Helpers preserve callback failures
  and expose application exceptions; HTTP sanitizes them as internal errors.
  This slice supports one user-role text message, static listing and get.
  Implement optional `complete/3` to suggest declared argument values. It receives
  the argument name, current value and request with previously resolved
  `request.arguments`. Return `{:ok, values}` in relevance order or an error tuple.
  Suggestions do not constrain the values accepted by get/2.
  Multiple/rich messages, elicitation and subscriptions are follow-ups.
  """
  defstruct messages: []
  @type t :: %__MODULE__{messages: [map()]}
  @callback get(%{optional(String.t()) => String.t()}, Portico.Request.t()) ::
              {:ok, t()} | {:error, term()}

  @doc """
  Suggests argument values for a prompt or resource template. Optional callback.
  Previously resolved arguments are available in request.arguments.
  Return all matches in relevance order; Portico emits at most 100 and derives
  total/hasMore. No callback means no suggestions for that declaration.
  """
  @callback complete(String.t(), String.t(), Portico.Request.t()) ::
              {:ok, [String.t()]} | {:error, term()}
  @optional_callbacks complete: 3

  @doc "Builds one user-role text message, returning an error tuple for invalid text."
  @spec text(String.t()) :: {:ok, t()} | {:error, :invalid_text}
  def text(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, %__MODULE__{messages: [%{role: "user", content: %{type: "text", text: value}}]}},
      else: {:error, :invalid_text}
  end

  def text(_), do: {:error, :invalid_text}

  @doc false
  defmacro __using__(options) do
    quote do
      @behaviour Portico.Prompt
      @portico_prompt Portico.Server.Compiler.prompt_metadata!(unquote(options), __ENV__)
      @before_compile Portico.Prompt
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:get, 2}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Portico.Prompt requires a public get/2 callback"
    end

    metadata = Module.get_attribute(env.module, :portico_prompt)

    quote do
      @doc false
      def __portico_prompt__, do: unquote(Macro.escape(metadata))
    end
  end
end
