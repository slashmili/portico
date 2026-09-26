defmodule PorticoExample.ReportApprovals do
  @moduledoc false
  use Agent

  # Demo-only application state, independent of Portico's signed continuations.
  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def create(user) do
    id = random()
    entry = %{user: user, complete: false, confirmation: random(), expires: now() + 300}

    Agent.get_and_update(__MODULE__, fn entries ->
      entries = Map.reject(entries, fn {_, entry} -> entry.expires <= now() end)

      if map_size(entries) < 1_000,
        do: {{:ok, id}, Map.put(entries, id, entry)},
        else: {{:error, :busy}, entries}
    end)
  end

  def get(id, user) do
    Agent.get(__MODULE__, fn entries ->
      case entries[id] do
        %{user: ^user, expires: expires} = entry ->
          if expires > now(), do: {:ok, entry}, else: {:error, :not_found}

        _ ->
          {:error, :not_found}
      end
    end)
  end

  def complete(id, user, confirmation) do
    Agent.get_and_update(__MODULE__, fn entries ->
      case entries[id] do
        %{user: ^user, confirmation: ^confirmation, expires: expires} = entry ->
          if expires > now(),
            do: {:ok, Map.put(entries, id, %{entry | complete: true})},
            else: {{:error, :not_found}, entries}

        _ ->
          {{:error, :not_found}, entries}
      end
    end)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  defp now, do: System.monotonic_time(:second)
end
