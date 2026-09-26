defmodule Portico.Test.Context do
  @moduledoc """
  Configuration for direct tool and resource tests, supplied as `:mcp` by `use Portico.Test`.

  Holds the server module, default application assigns, and client metadata.
  Override `protocol_version`, `client_info`, or `client_capabilities` in setup
  to exercise metadata checks. Client information defaults to absent.
  It is an immutable
  value, not an HTTP connection or a persistent tool session. Every invocation
  creates a fresh `Portico.Request` from these defaults.
  """

  @enforce_keys [:server]
  defstruct [
    :server,
    :client_info,
    protocol_version: "2026-07-28",
    client_capabilities: %{},
    assigns: %{}
  ]

  @type t :: %__MODULE__{
          server: module(),
          protocol_version: String.t(),
          client_info: map() | nil,
          client_capabilities: map(),
          assigns: %{optional(atom()) => term()}
        }
end
