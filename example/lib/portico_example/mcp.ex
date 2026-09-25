defmodule PorticoExample.MCP do
  use Portico.Server, name: "portico-example", version: "0.1.0"

  tool "add", PorticoExample.Tools.Add
  tool "choose_color", PorticoExample.Tools.ChooseColor
  tool "count", PorticoExample.Tools.Count
  tool "greet", PorticoExample.Tools.Greet
end
