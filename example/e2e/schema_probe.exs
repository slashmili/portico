# Compile isolated declarations and inspect their actual tools/list response.
# Negative cases must fail at compilation, before a client can see invalid metadata.
cases = [
  {"missing", %{}},
  {"array", %{type: "array"}},
  {"union", %{type: ["object", "null"]}},
  {"reference_only", %{"$defs" => %{"args" => %{"type" => "object"}}, "$ref" => "#/$defs/args"}},
  {"object", %{type: "object", additionalProperties: false}},
  {"composition",
   %{
     "type" => "object",
     "$defs" => %{"args" => %{"required" => ["name"]}},
     "allOf" => [%{"$ref" => "#/$defs/args"}],
     "properties" => %{"name" => %{"type" => "string"}}
   }}
]

results =
  for {{name, schema}, index} <- Enum.with_index(cases) do
    tool = Module.concat(PorticoSchemaProbe, "Tool#{index}")
    server = Module.concat(PorticoSchemaProbe, "Server#{index}")

    try do
      Code.compile_quoted(
        quote do
          defmodule unquote(tool) do
            use Portico.Tool, input_schema: unquote(Macro.escape(schema))
            @impl true
            def call(_, _) do
              {:ok, result} = Portico.Result.text("ok")
              {:ok, result}
            end
          end

          defmodule unquote(server) do
            use Portico.Server, name: "schema-probe", version: "1"
            tool unquote(name), unquote(tool)
          end
        end
      )

      {:reply, response} =
        Portico.Protocol.Dispatcher.dispatch(server, %{
          "jsonrpc" => "2.0",
          "id" => index,
          "method" => "tools/list",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      %{name: name, compiled: true, result: response["result"]}
    rescue
      error in CompileError -> %{name: name, compiled: false, error: error.description}
    end
  end

IO.puts("PORTICO_SCHEMA_PROBE=" <> JSON.encode!(results))
