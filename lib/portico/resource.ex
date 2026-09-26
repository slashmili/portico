defmodule Portico.Resource do
  @moduledoc """
  Declares a text or binary resource and builds its content.

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

  Templates use the same callback:
  `resource_template "company://handbook/{section}", MyApp.Resources.HandbookSection`.
  Read decoded variables from `request.resource_params["section"]`. Variables
  occupy whole path segments and are decoded once; names remain strings. Static
  routes take precedence. Duplicate template shapes fail at compilation; other
  ambiguous matches return `{:error, :ambiguous_resource}` in helpers and a
  sanitized internal error over HTTP. Treat decoded values as untrusted input;
  an encoded slash becomes a slash, not another routing segment.

  This slice returns one UTF-8 text or binary item per read. The requested concrete URI and MIME
  type are supplied by Portico, overriding those fields in callback content.
  Use `blob/1` for raw bytes; the protocol encodes them as base64.
  Multiple contents, elicitation during reads and
  subscriptions are not implemented yet. Listings and reads use private caching
  with zero TTL. Catalogs are static and are not filtered by caller identity.
  """
  defstruct [:text, :blob, :uri, :mime_type]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          blob: binary() | nil,
          uri: String.t() | nil,
          mime_type: String.t() | nil
        }
  @callback read(Portico.Request.t()) :: {:ok, t()} | {:error, term()}

  @doc "Builds UTF-8 text content, returning an error tuple for invalid values."
  @spec text(String.t()) :: {:ok, t()} | {:error, :invalid_text}
  def text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, %__MODULE__{text: value}}, else: {:error, :invalid_text}
  end

  def text(_), do: {:error, :invalid_text}

  @doc """
  Builds binary content from raw bytes, returning an error tuple for other values.

  The struct stores raw bytes in `blob`, including empty binaries. Portico encodes
  them as base64 only in protocol responses. Do not base64-encode the input.
  """
  @spec blob(binary()) :: {:ok, t()} | {:error, :invalid_blob}
  def blob(value) when is_binary(value), do: {:ok, %__MODULE__{blob: value}}
  def blob(_), do: {:error, :invalid_blob}

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
