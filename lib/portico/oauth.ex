defmodule Portico.OAuth do
  @moduledoc """
  Optional OAuth resource-server integration for a protected MCP endpoint.

  Run this plug before `Portico.Plug`, scoped to the protected endpoint. Successful
  verification adds assigns to the connection; configure `Portico.Plug`'s `:assigns`
  to expose selected keys to tools. Authentication runs on every HTTP request,
  including continuations. Application callbacks still own operation authorization.

      plug Portico.OAuth,
        resource: "https://example.com/mcp",
        authorization_servers: ["https://auth.example.com"],
        scopes: ["mcp:access"],
        verify_token: &MyApp.Auth.verify_mcp_token/2

  Also mount a public GET route at `/.well-known/oauth-protected-resource/mcp`
  and call `metadata/2` with the same initialized options. For resource paths
  such as `/api/mcp`, append that entire path to the well-known prefix. For a
  resource with no path (or `/`), use the prefix alone. Route discovery outside
  the authentication pipeline. URLs come from configuration, never Host headers.

  Options (validated at initialization):

    * `:resource` — required canonical, absolute resource URL.
    * `:authorization_servers` — required nonempty list of authorization-server
      issuer URLs. These are advertised; Portico does not contact them.
    * `:scopes` — scope strings required for this endpoint, default `[]`.
      Advertised as supported scopes and included in authentication challenges.
    * `:verify_token` — required function of arity two. Receives the bearer token
      and `%{resource: url, scopes: scopes}`. Returns `{:ok, assigns}` (an atom-keyed
      map), `{:error, :invalid_token}`, or `{:error, :insufficient_scope}`.
      `{:error, :temporarily_unavailable}` returns HTTP 503.

  The verifier is the trust boundary: it MUST validate token authenticity,
  trusted issuer, expiry, audience matching the resource, and required scopes.
  JWT decoding alone is not validation. Opaque tokens need trusted introspection
  or a local token store. Portico supplies no JWT, introspection, login, consent,
  token issuance, registration, or refresh implementation.

  URLs require HTTPS, except HTTP on localhost, 127.0.0.1 or ::1 for development.
  This initial API disallows URL credentials, queries and fragments. Configure
  public URLs explicitly when running behind a proxy. The host owns CORS and
  may need to expose `WWW-Authenticate` for browser clients.

  Missing/invalid credentials halt with 401; insufficient scope with 403;
  malformed Bearer credentials with 400. Callback failures or invalid return
  shapes halt with a generic 500. Callback exceptions, throws and exits are
  contained; neither tokens nor callback error details are logged. Existing
  halted connections are preserved. Only the Authorization header supplies a
  token; query and body credentials are never used.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @doc "Validates OAuth configuration and prepares options for `call/2` and `metadata/2`."
  @impl true
  def init(options) do
    options =
      Keyword.validate!(options, [:resource, :authorization_servers, :verify_token, scopes: []])

    if length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))),
      do: raise(ArgumentError, "duplicate OAuth option")

    resource = Keyword.get(options, :resource)
    uri = url!(resource)
    servers = Keyword.get(options, :authorization_servers)

    unless is_list(servers) and servers != [],
      do: raise(ArgumentError, "expected nonempty :authorization_servers")

    Enum.each(servers, &url!/1)
    scopes = options[:scopes]

    unless is_list(scopes) and Enum.all?(scopes, &scope?/1) and Enum.uniq(scopes) == scopes,
      do: raise(ArgumentError, "expected :scopes to contain unique OAuth scope strings")

    unless is_function(options[:verify_token], 2),
      do: raise(ArgumentError, "expected :verify_token to be a function of arity two")

    path = if uri.path in [nil, "/"], do: "", else: uri.path
    metadata_url = URI.to_string(%{uri | path: "/.well-known/oauth-protected-resource" <> path})

    %{
      resource: resource,
      authorization_servers: servers,
      scopes: scopes,
      verify_token: options[:verify_token],
      metadata_url: metadata_url,
      metadata_body:
        JSON.encode!(%{
          resource: resource,
          authorization_servers: servers,
          scopes_supported: scopes,
          bearer_methods_supported: ["header"]
        })
    }
  end

  @doc "Authenticates a request, assigning verified identity or halting with an HTTP error."
  @impl true
  def call(%{halted: true} = conn, _options), do: conn

  def call(conn, options) do
    case bearer(conn) do
      {:ok, token} -> authenticate(conn, token, options)
      :missing -> challenge(conn, options, 401, nil)
      :malformed -> challenge(conn, options, 400, "invalid_request")
    end
  end

  @doc """
  Serves public protected-resource metadata using options returned by `init/1`.

  Mount on the well-known path derived from `:resource`, independently of the
  protected endpoint. GET and HEAD are supported; other methods receive 405.
  """
  def metadata(%{halted: true} = conn, _options), do: conn

  def metadata(conn, options) do
    if conn.method in ["GET", "HEAD"] do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, if(conn.method == "HEAD", do: "", else: options.metadata_body))
      |> halt()
    else
      conn |> put_resp_header("allow", "GET, HEAD") |> send_resp(405, "") |> halt()
    end
  end

  defp authenticate(conn, token, options) do
    case verify(token, options) do
      {:ok, assigns} when is_map(assigns) and not is_struct(assigns) ->
        if Enum.all?(Map.keys(assigns), &is_atom/1) do
          Enum.reduce(assigns, conn, fn {key, value}, conn -> assign(conn, key, value) end)
        else
          failure(conn)
        end

      {:error, :invalid_token} ->
        challenge(conn, options, 401, "invalid_token")

      {:error, :insufficient_scope} ->
        challenge(conn, options, 403, "insufficient_scope")

      {:error, :temporarily_unavailable} ->
        finish(conn, 503)

      _ ->
        failure(conn)
    end
  end

  defp verify(token, options) do
    options.verify_token.(token, Map.take(options, [:resource, :scopes]))
  rescue
    _ -> {:error, :verifier_failed}
  catch
    _, _ -> {:error, :verifier_failed}
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        :missing

      [header] ->
        case Regex.run(~r/\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i, header) do
          [_, token] -> {:ok, token}
          _ -> if Regex.match?(~r/\ABearer(?:\s|\z)/i, header), do: :malformed, else: :missing
        end

      _ ->
        :malformed
    end
  end

  defp challenge(conn, options, status, error) do
    fields = [~s(resource_metadata="#{options.metadata_url}")]
    fields = if error, do: fields ++ [~s(error="#{error}")], else: fields

    fields =
      if options.scopes == [],
        do: fields,
        else: fields ++ [~s(scope="#{Enum.join(options.scopes, " ")}")]

    conn
    |> put_resp_header("www-authenticate", "Bearer " <> Enum.join(fields, ", "))
    |> finish(status)
  end

  defp failure(conn) do
    Logger.error("Portico OAuth verifier failed")
    finish(conn, 500)
  end

  defp finish(conn, status),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(status, "") |> halt()

  defp scope?(scope),
    do: is_binary(scope) and Regex.match?(~r/\A[\x21\x23-\x5B\x5D-\x7E]+\z/, scope)

  defp url!(value) do
    with true <- is_binary(value) and Regex.match?(~r/\A[\x21-\x7E]+\z/, value),
         false <- String.contains?(value, ["\"", "\\"]),
         {:ok, uri} <- URI.new(value),
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_integer(uri.port) and uri.port > 0 and uri.port <= 65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"]) do
      uri
    else
      _ ->
        raise ArgumentError,
              "expected an absolute HTTPS OAuth URL (HTTP loopback allowed), without credentials, query or fragment"
    end
  end
end
