defmodule PorticoExample.ReportApprovals do
  @moduledoc false
  use Agent

  # Demo-only application state, independent of Portico's signed continuations.
  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def create(user) do
    id = random()
    entry = %{user: user, status: :pending, confirmation: random(), expires: now() + 300}

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

  def decide(id, user, confirmation, decision) when decision in [:approved, :rejected] do
    Agent.get_and_update(__MODULE__, fn entries ->
      case entries[id] do
        %{user: ^user, confirmation: ^confirmation, expires: expires} = entry ->
          cond do
            expires <= now() -> {{:error, :not_found}, entries}
            entry.status == decision -> {:ok, entries}
            entry.status == :pending -> {:ok, Map.put(entries, id, %{entry | status: decision})}
            true -> {{:error, :already_decided}, entries}
          end

        _ ->
          {{:error, :not_found}, entries}
      end
    end)
  end

  def decide(_, _, _, _), do: {:error, :invalid_decision}

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  defp now, do: System.monotonic_time(:second)
end
