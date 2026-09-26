defmodule PorticoExample.Resources.Sample do
  use Portico.Resource,
    name: "sample",
    description: "Four sample bytes.",
    mime_type: "application/octet-stream"

  def read(_request) do
    {:ok, content} = Portico.Resource.blob(<<0, 1, 2, 255>>)
    {:ok, content}
  end
end
