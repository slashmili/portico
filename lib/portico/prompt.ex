defmodule Portico.Prompt do
  @moduledoc ~S"""
  Declares a prompt and builds ordered user/assistant text messages.

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
  Text messages support `:user` (default) and `:assistant` roles.
  Implement optional `complete/3` to suggest declared argument values. It receives
  the argument name, current value and request with previously resolved
  `request.arguments`. Return `{:ok, values}` in relevance order or an error tuple.
  Suggestions do not constrain the values accepted by get/2.
  Rich messages, elicitation and subscriptions are follow-ups.
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

  @type text_error :: :invalid_text | :invalid_options | :invalid_role | :invalid_prompt

  @doc "Builds one user-role text message, returning an error tuple for invalid text."
  @spec text(String.t()) :: {:ok, t()} | {:error, :invalid_text}
  def text(value), do: text(%__MODULE__{}, value, [])

  @doc """
  Builds a text message with options, or appends a user message to a prompt.

      {:ok, prompt} = Portico.Prompt.text("Review this code.")
      {:ok, prompt} = Portico.Prompt.text(prompt, "1 + 1")

  For a new assistant message, use `text("Example answer", role: :assistant)`.
  Only `:role` is accepted, with `:user` (default) or `:assistant`. Unknown or
  duplicate options return `{:error, :invalid_options}`; invalid roles return
  `{:error, :invalid_role}`. Text must be a UTF-8 string; empty text is allowed.
  """
  @spec text(t(), String.t()) :: {:ok, t()} | {:error, text_error()}
  @spec text(String.t(), keyword()) :: {:ok, t()} | {:error, text_error()}
  def text(%__MODULE__{} = prompt, value), do: text(prompt, value, [])
  def text(value, options), do: text(%__MODULE__{}, value, options)

  @doc """
  Appends a text message, preserving message order and the original prompt.

      {:ok, prompt} = Portico.Prompt.text("What is 1 + 1?")
      {:ok, prompt} = Portico.Prompt.text(prompt, "2", role: :assistant)
      {:ok, prompt} = Portico.Prompt.text(prompt, "Now explain why.")

  A fresh `%Portico.Prompt{}` can be used as the initial builder. A completed
  prompt must have at least one message. Invalid existing messages return
  `{:error, :invalid_prompt}`. Options follow `text/2`.
  """
  @spec text(t(), String.t(), keyword()) :: {:ok, t()} | {:error, text_error()}
  def text(%__MODULE__{} = prompt, value, options) do
    with true <- is_binary(value) and String.valid?(value),
         {:ok, role} <- role(options),
         {:ok, prompt} <- builder(prompt) do
      message = %{role: Atom.to_string(role), content: %{type: "text", text: value}}
      {:ok, %{prompt | messages: prompt.messages ++ [message]}}
    else
      false -> {:error, :invalid_text}
      error -> error
    end
  end

  def text(_, _, _), do: {:error, :invalid_prompt}

  @doc false
  def validate(%__MODULE__{messages: messages}) when is_list(messages) and messages != [] do
    if valid_messages?(messages) do
      {:ok,
       %__MODULE__{
         messages:
           Enum.map(messages, fn message ->
             %{role: message.role, content: %{type: "text", text: message.content.text}}
           end)
       }}
    else
      {:error, :invalid_prompt}
    end
  end

  def validate(_), do: {:error, :invalid_prompt}

  defp builder(%__MODULE__{messages: []} = prompt), do: {:ok, prompt}
  defp builder(prompt), do: validate(prompt)

  defp valid_messages?([]), do: true
  defp valid_messages?([message | rest]), do: valid_message?(message) and valid_messages?(rest)
  defp valid_messages?(_), do: false

  defp valid_message?(%{role: role, content: %{type: "text", text: text}})
       when role in ["user", "assistant"], do: is_binary(text) and String.valid?(text)

  defp valid_message?(_), do: false

  defp role(options) do
    if is_list(options) and Keyword.keyword?(options) and
         Keyword.keys(options) in [[], [:role]] do
      case Keyword.get(options, :role, :user) do
        role when role in [:user, :assistant] -> {:ok, role}
        _ -> {:error, :invalid_role}
      end
    else
      {:error, :invalid_options}
    end
  end

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
