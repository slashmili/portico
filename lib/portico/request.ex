defmodule Portico.Request do
  @moduledoc """
  Application context for one Portico invocation.

  Assigns hold application data passed to tool callbacks. Each invocation starts
  with a fresh request; assigns are not retained between requests.

  Protocol invocation fills `id`, `method`, `protocol_version`, `client_info`,
  and `client_capabilities` from checked request metadata. Direct application
  test calls currently leave these fields at their defaults. Client information
  and capabilities describe the caller's claims, not authenticated identity.

  This struct does not authenticate its contents. The host application is
  responsible for establishing identity before assigning it to a request.
  """

  defstruct [
    :id,
    :method,
    :protocol_version,
    :client_info,
    client_capabilities: %{},
    assigns: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | integer() | nil,
          method: String.t() | nil,
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map(),
          assigns: %{optional(atom()) => term()}
        }

  @doc """
  Adds or replaces an application assign, returning the updated request.

  Keys must be atoms supplied by application code. Incoming strings are never
  converted to atoms.

  ## Examples

      iex> request = Portico.Request.assign(%Portico.Request{}, :locale, "en")
      iex> request.assigns
      %{locale: "en"}
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = request, key, value) when is_atom(key) do
    %{request | assigns: Map.put(request.assigns, key, value)}
  end
end
