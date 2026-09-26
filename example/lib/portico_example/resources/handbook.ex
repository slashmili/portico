defmodule PorticoExample.Resources.Handbook do
  use Portico.Resource,
    name: "handbook",
    description: "A sample company handbook.",
    mime_type: "text/plain"

  @impl true
  def read(_request) do
    {:ok, content} =
      Portico.Resource.text("Welcome to the company. Ask questions and share what you learn.")

    {:ok, content}
  end
end
