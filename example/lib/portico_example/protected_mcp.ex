defmodule PorticoExample.ProtectedMCP do
  use Portico.Server, name: "portico-protected-example", version: "0.1.0"

  tool "whoami", PorticoExample.Tools.Whoami
end
