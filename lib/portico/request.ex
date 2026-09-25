defmodule Portico.Request do
  @moduledoc """
  Application context for one Portico invocation.

  Assigns hold application data passed to tool callbacks. Each invocation starts
  with a fresh request; assigns are not retained between requests.

  Protocol invocation fills `id`, `method`, `protocol_version`, `client_info`,
  `client_capabilities`, and optional `progress_token` from checked request metadata. Test helpers supply
  valid default metadata, configurable through `Portico.Test.Context`. Client information
  and capabilities describe the caller's claims, not authenticated identity.

  This struct does not authenticate its contents. The host application is
  responsible for establishing identity before assigning it to a request.
  """

  defstruct [
    :id,
    :method,
    :protocol_version,
    :client_info,
    :progress_token,
    client_capabilities: %{},
    assigns: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | integer() | nil,
          method: String.t() | nil,
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          progress_token: String.t() | integer() | nil,
          client_capabilities: map(),
          assigns: %{optional(atom()) => term()}
        }

  @type assign_error :: :invalid_request | :invalid_assigns | :invalid_assign_key

  @doc """
  Adds or replaces an application assign, returning the updated request.

  Keys must be atoms supplied by application code. Incoming strings are never
  converted to atoms. Existing assigns must be a plain map with atom keys.

  Invalid input returns `{:error, reason}` without raising. Validation checks
  the request first (`:invalid_request`), then its assigns (`:invalid_assigns`),
  then the new key (`:invalid_assign_key`). Successful calls return the updated
  request directly. Handle an error before continuing a request pipeline.

  ## Examples

      iex> request = Portico.Request.assign(%Portico.Request{}, :locale, "en")
      iex> request.assigns
      %{locale: "en"}
  """
  @spec assign(t(), atom(), term()) :: t() | {:error, assign_error()}
  def assign(%__MODULE__{assigns: assigns} = request, key, value) do
    cond do
      not is_map(assigns) or is_struct(assigns) ->
        {:error, :invalid_assigns}

      not Enum.all?(Map.keys(assigns), &is_atom/1) ->
        {:error, :invalid_assigns}

      not is_atom(key) ->
        {:error, :invalid_assign_key}

      true ->
        %{request | assigns: Map.put(assigns, key, value)}
    end
  end

  def assign(_request, _key, _value), do: {:error, :invalid_request}
end
