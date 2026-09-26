defmodule Portico.Elicitation do
  @moduledoc """
  Default verification for elicitation continuations and shared input-token signing.

  Configure a runtime key of at least 32 bytes per server:

      config :portico, MyApp.MCP, elicitation_key: System.fetch_env!("ELICITATION_KEY")

  Continuations expire after five minutes and bind the form, URL or sampling request and application state
  to the server and either tool/arguments or resource route/requested URI. They are signed, not encrypted or
  single-use. Keep secrets out of state. Changing the key invalidates existing
  tokens; instances sharing a key can resume each other's tokens.

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
    with {:ok, key} <- key(request.server) do
      payload = %{
        version: 1,
        server: request.server,
        tool: request.tool_name,
        arguments: request.arguments,
        resource_route: request.resource_route,
        resource_uri: request.resource_uri,
        form: form,
        state: state
      }

      {:ok, Plug.Crypto.sign(key, @salt, payload, max_age: 300)}
    end
  rescue
    _ -> {:error, :invalid_request_state}
  end

  @doc false
  def open(token, %Request{} = request) when is_binary(token) do
    with {:ok, key} <- key(request.server),
         {:ok, %{version: 1, form: %Input{}} = payload} <-
           Plug.Crypto.verify(key, @salt, token, max_age: 300),
         true <-
           payload.server == request.server and payload.tool == request.tool_name and
             payload.arguments == request.arguments and
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

  defp key(server) do
    options = Application.get_env(:portico, server, [])
    key = if Keyword.keyword?(options), do: options[:elicitation_key]

    if is_binary(key) and byte_size(key) >= 32,
      do: {:ok, key},
      else: {:error, :elicitation_key_missing}
  end
end
