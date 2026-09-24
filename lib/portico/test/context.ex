defmodule Portico.Test.Context do
  @moduledoc """
  Configuration for direct tool tests, supplied as `:mcp` by `use Portico.Test`.

  Holds the server module and default application assigns. It is an immutable
  value, not an HTTP connection or a persistent tool session. Every invocation
  creates a fresh `Portico.Request` from these defaults.
  """

  @enforce_keys [:server]
  defstruct [:server, assigns: %{}]

  @type t :: %__MODULE__{server: module(), assigns: %{optional(atom()) => term()}}
end
