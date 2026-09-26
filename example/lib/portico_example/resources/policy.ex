defmodule PorticoExample.Resources.Policy do
  use Portico.Resource,
    name: "policy",
    description: "Look up the leave or expenses policy.",
    mime_type: "text/plain"

  @policies %{
    "leave" => "Request leave through your manager.",
    "expenses" => "Keep receipts for business expenses."
  }

  @impl true
  def complete("name", prefix, _request) do
    {:ok, @policies |> Map.keys() |> Enum.sort() |> Enum.filter(&String.starts_with?(&1, prefix))}
  end

  @impl true
  def read(%{resource_params: %{"name" => name}}) do
    case Map.fetch(@policies, name) do
      {:ok, text} ->
        {:ok, content} = Portico.Resource.text(text)
        {:ok, content}

      :error ->
        {:error, :resource_not_found}
    end
  end
end
