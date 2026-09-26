defmodule PorticoExample.Resources.HandbookSection do
  use Portico.Resource,
    name: "handbook-section",
    description: "A generated handbook section heading.",
    mime_type: "text/plain"

  def read(%{resource_params: %{"section" => section}}) do
    {:ok, content} = Portico.Resource.text("Handbook section: #{section}")
    {:ok, content}
  end
end
