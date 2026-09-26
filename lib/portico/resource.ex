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
  as internal errors. The specific tuple `{:error, :resource_not_found}` reports
  a missing resource and maps to MCP invalid params (`-32602`). Other callback
  errors remain internal errors. Authorization belongs to the application.

  Templates use the same callback:
  `resource_template "company://handbook/{section}", MyApp.Resources.HandbookSection`.
  Read decoded variables from `request.resource_params["section"]`. Variables
  occupy whole path segments and are decoded once; names remain strings. Static
  routes take precedence. Duplicate template shapes fail at compilation; other
  ambiguous matches return `{:error, :ambiguous_resource}` in helpers and a
  sanitized internal error over HTTP. Treat decoded values as untrusted input;
  an encoded slash becomes a slash, not another routing segment.

  Return a single content struct or a list of content structs. For a single item,
  Portico supplies the requested URI and declared MIME type, overriding callback
  metadata. For lists, every item requires its own absolute URI; MIME type is
  optional per item and does not inherit the route's MIME type. Order is preserved.
  An empty list represents an existing resource with no contents, not a missing resource.
  Invalid items reject the entire read with `:invalid_resource` in test helpers.
  Use `blob/1` for raw bytes; the protocol encodes them as base64.
  Elicitation during reads and
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
  @callback read(Portico.Request.t()) :: {:ok, t() | [t()]} | {:error, term()}

  @type content_error ::
          :invalid_text | :invalid_blob | :invalid_options | :invalid_uri | :invalid_mime_type

  @doc """
  Builds UTF-8 text content. Optional `:uri` must be an absolute URI and
  `:mime_type` a UTF-8 string. Unknown or duplicate options return an error.
  """
  @spec text(String.t(), keyword()) :: {:ok, t()} | {:error, content_error()}
  def text(value, options \\ [])

  def text(value, options) when is_binary(value) do
    if String.valid?(value),
      do: with_metadata(%__MODULE__{text: value}, options),
      else: {:error, :invalid_text}
  end

  def text(_, _), do: {:error, :invalid_text}

  @doc """
  Builds binary content from raw bytes. Accepts the same metadata options as text/2.

  The struct stores raw bytes in `blob`, including empty binaries. Portico encodes
  them as base64 only in protocol responses. Do not base64-encode the input.
  """
  @spec blob(binary(), keyword()) :: {:ok, t()} | {:error, content_error()}
  def blob(value, options \\ [])

  def blob(value, options) when is_binary(value),
    do: with_metadata(%__MODULE__{blob: value}, options)

  def blob(_, _), do: {:error, :invalid_blob}

  defp with_metadata(content, options) do
    cond do
      not Keyword.keyword?(options) ->
        {:error, :invalid_options}

      length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))) or
          Enum.any?(Keyword.keys(options), &(&1 not in [:uri, :mime_type])) ->
        {:error, :invalid_options}

      Keyword.has_key?(options, :uri) and not valid_uri?(options[:uri]) ->
        {:error, :invalid_uri}

      Keyword.has_key?(options, :mime_type) and
          not (is_binary(options[:mime_type]) and String.valid?(options[:mime_type])) ->
        {:error, :invalid_mime_type}

      true ->
        {:ok, %{content | uri: options[:uri], mime_type: options[:mime_type]}}
    end
  end

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
