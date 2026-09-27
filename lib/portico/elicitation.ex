defmodule Portico.Elicitation do
  @moduledoc """
  Default verification for elicitation continuations and shared input-token signing.

  Configure a runtime key of at least 32 bytes per server:

      config :portico, MyApp.MCP, elicitation_key: System.fetch_env!("ELICITATION_KEY")

  Generated signed tokens are limited to 64,000 bytes by default. Override per
  server with `max_request_state_bytes: 128_000` alongside `elicitation_key`.
  The limit must be a positive integer; invalid runtime configuration returns
  `{:error, :invalid_request_state_limit}`. Oversized tokens return
  `{:error, :request_state_too_large}` before an input request is emitted.
  This applies to form, URL and sampling continuations, including resources.
  HTTP reports generation failures as a sanitized internal error; testing
  helpers preserve the error tuple. The limit measures the final signed token,
  including encoding overhead, and does not bound the entire retry body or the
  memory used to construct it. Incoming token verification is unchanged.

  Continuations expire after five minutes and bind the form, URL or sampling request and application state
  to the server and either tool/arguments or resource route/requested URI. They are signed, not encrypted or
  single-use. Keep secrets out of state. Changing the key invalidates existing
  tokens; instances sharing a key can resume each other's tokens.

  Tokens carry a SHA-256 digest of the arguments, not another copy. Clients
  resend arguments on retry; verification checks their digest. Object-key order
  is ignored, while array order and JSON value types are preserved. Forms and
  application state still contribute to token size. This envelope version rejects
  tokens minted before the argument-digest change; restart those open flows.

  A tool or resource may set `elicitation_verifier: &MyApp.Elicitation.verify/2`. The function
  receives the wire token and fresh request and returns `{:ok, application_state}`
  or `{:error, reason}`. It can call `Portico.Elicitation.verify/2` then enforce
  identity or application policy. Portico always checks the signed input envelope
  independently before validating answers, even with a custom verifier.

  Sampling uses this same key and signed envelope but does not invoke the
  elicitation-specific custom verifier. Sampling handlers check application
  authorization using fresh request assigns in `handle_input/3`.

  There is no automatic user authentication. Applications bind state to their
  authenticated identity and enforce that binding in the custom verifier.
  """
  alias Portico.{Input, Request}
  @salt "portico:elicitation:v1"

  @doc "Verifies a token and restores its application state."
  @spec verify(String.t(), Request.t()) :: {:ok, term()} | {:error, atom()}
  def verify(token, request) do
    with {:ok, payload} <- open(token, request), do: {:ok, payload.state}
  end

  @doc false
  def seal(%Input{} = form, state, %Request{} = request) do
    with {:ok, key} <- key(request.server),
         {:ok, limit} <- state_limit(request.server) do
      payload = %{
        version: 2,
        server: request.server,
        tool: request.tool_name,
        arguments_digest: arguments_digest(request.arguments),
        resource_route: request.resource_route,
        resource_uri: request.resource_uri,
        form: form,
        state: state
      }

      token = Plug.Crypto.sign(key, @salt, payload, max_age: 300)
      if byte_size(token) <= limit, do: {:ok, token}, else: {:error, :request_state_too_large}
    end
  rescue
    _ -> {:error, :invalid_request_state}
  end

  @doc false
  def open(token, %Request{} = request) when is_binary(token) do
    with {:ok, key} <- key(request.server),
         {:ok, %{version: 2, form: %Input{}} = payload} <-
           Plug.Crypto.verify(key, @salt, token, max_age: 300),
         true <-
           payload.server == request.server and payload.tool == request.tool_name and
             payload.arguments_digest == arguments_digest(request.arguments) and
             Map.get(payload, :resource_route) == request.resource_route and
             Map.get(payload, :resource_uri) == request.resource_uri do
      {:ok, payload}
    else
      {:error, :elicitation_key_missing} = error -> error
      _ -> {:error, :invalid_request_state}
    end
  rescue
    _ -> {:error, :invalid_request_state}
  end

  def open(_token, _request), do: {:error, :invalid_request_state}

  # JSON objects are unordered; arrays retain their order. Tagged containers
  # distinguish an object from an array with similar contents. The canonical
  # term contains no maps, so its encoding is independent of map insertion order.
  defp arguments_digest(arguments) do
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical(arguments)))
  end

  defp canonical(value) when is_map(value) do
    {:object,
     value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, item} -> {key, canonical(item)} end)}
  end

  defp canonical(value) when is_list(value), do: {:array, Enum.map(value, &canonical/1)}
  defp canonical(value), do: value

  defp state_limit(server) do
    limit =
      Application.get_env(:portico, server, []) |> Keyword.get(:max_request_state_bytes, 64_000)

    if is_integer(limit) and limit > 0,
      do: {:ok, limit},
      else: {:error, :invalid_request_state_limit}
  end

  defp key(server) do
    options = Application.get_env(:portico, server, [])
    key = if Keyword.keyword?(options), do: options[:elicitation_key]

    if is_binary(key) and byte_size(key) >= 32,
      do: {:ok, key},
      else: {:error, :elicitation_key_missing}
  end
end
