defmodule Portico.Resource do
  @moduledoc """
  Declares a static text resource and builds its content.

      defmodule MyApp.Resources.Handbook do
        use Portico.Resource, name: "handbook", mime_type: "text/plain"

        def read(_request) do
          {:ok, content} = Portico.Resource.text("Welcome to the company.")
          {:ok, content}
        end
      end

  Register it with `resource "company://handbook", MyApp.Resources.Handbook` in
  your server. The URI identifies a declared callback; Portico does not fetch URLs
  or read files automatically. Metadata supports required `:name` and optional
  `:description` and `:mime_type`. Invalid declarations fail at compilation.

  `read/1` receives a fresh `Portico.Request` with `resource_uri` and application
  assigns. Return `{:ok, content}` or `{:error, reason}`. Helpers preserve failures
  as tuples and propagate application exceptions; HTTP sanitizes callback failures
  as internal errors. Authorization belongs to the application.

  This first slice returns one UTF-8 text item per read. The declared URI and MIME
  type are supplied by Portico, overriding those fields in callback content.
  Templates, binary content, multiple contents, elicitation during reads and
  subscriptions are not implemented yet. Listings and reads use private caching
  with zero TTL. Catalogs are static and are not filtered by caller identity.
  """
  defstruct [:text, :uri, :mime_type]
  @type t :: %__MODULE__{text: String.t(), uri: String.t() | nil, mime_type: String.t() | nil}
  @callback read(Portico.Request.t()) :: {:ok, t()} | {:error, term()}

  @doc "Builds UTF-8 text content, returning an error tuple for invalid values."
  @spec text(String.t()) :: {:ok, t()} | {:error, :invalid_text}
  def text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, %__MODULE__{text: value}}, else: {:error, :invalid_text}
  end

  def text(_), do: {:error, :invalid_text}

  @doc false
  def valid_uri?(value) when is_binary(value) do
    with true <- String.valid?(value),
         false <- Regex.match?(~r/[^\x21-\x7e]|[<>"{}|\\^`]|%(?![0-9a-fA-F]{2})/, value),
         {:ok, %URI{scheme: scheme}} when is_binary(scheme) <- URI.new(value) do
      true
    else
      _ -> false
    end
  end

  def valid_uri?(_), do: false

  @doc false
  defmacro __using__(options) do
    quote do
      @behaviour Portico.Resource
      @portico_resource Portico.Server.Compiler.resource_metadata!(unquote(options), __ENV__)
      @before_compile Portico.Resource
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:read, 1}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "Portico.Resource requires a public read/1 callback"
    end

    metadata = Module.get_attribute(env.module, :portico_resource)

    quote do
      @doc false
      def __portico_resource__, do: unquote(Macro.escape(metadata))
    end
  end
end
