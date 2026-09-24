defmodule PorticoExample.MCP do
  use Portico.Server, name: "portico-example", version: "0.1.0"

  tool "add", PorticoExample.Tools.Add
end
