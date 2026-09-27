defmodule PorticoExample.OAuthDemo do
  @moduledoc """
  Local resource-server showcase using two fixed opaque-token records.

  This is NOT an authorization server or a production token store. The advertised
  issuer is a placeholder, so automatic browser login cannot complete. Replace
  this verifier with your provider's JWT validation or introspection integration.
  Tokens expire one hour after the example starts.
  """

  def options do
    Portico.OAuth.init(
      resource: Application.fetch_env!(:portico_example, :public_url) <> "/protected/mcp",
      authorization_servers: ["https://auth.example.com"],
      scopes: ["mcp:access"],
      verify_token: &__MODULE__.verify_token/2
    )
  end

  def verify_token(token, %{resource: resource, scopes: scopes}) do
    audience = Application.fetch_env!(:portico_example, :public_url) <> "/protected/mcp"
    expires_at = Application.fetch_env!(:portico_example, :oauth_demo_expires_at)

    # In production these records come from trusted introspection or a token
    # store; JWT providers instead require signature and claim validation.
    records = %{
      "alice-demo-token" => %{
        subject: "alice",
        audience: audience,
        scopes: ["mcp:access"],
        expires_at: expires_at
      },
      "limited-demo-token" => %{
        subject: "bob",
        audience: audience,
        scopes: [],
        expires_at: expires_at
      }
    }

    case records[token] do
      nil ->
        {:error, :invalid_token}

      record ->
        cond do
          record.audience != resource or record.expires_at <= System.system_time(:second) ->
            {:error, :invalid_token}

          not Enum.all?(scopes, &(&1 in record.scopes)) ->
            {:error, :insufficient_scope}

          true ->
            {:ok, %{current_user: %{id: record.subject}}}
        end
    end
  end
end
