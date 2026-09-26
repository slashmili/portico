defmodule PorticoExample.Resources.Documents do
  use Portico.Resource,
    name: "documents",
    description: "Two generated documents.",
    mime_type: "inode/directory"

  def read(_request) do
    {:ok, readme} =
      Portico.Resource.text("Welcome",
        uri: "company://docs/readme",
        mime_type: "text/plain"
      )

    {:ok, guide} =
      Portico.Resource.text("# Getting started",
        uri: "company://docs/guide",
        mime_type: "text/markdown"
      )

    {:ok, [readme, guide]}
  end
end
