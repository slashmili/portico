defmodule Portico.ResourceBlobTest do
  use ExUnit.Case, async: true
  alias Portico.{Resource, Test}
  alias Portico.Protocol.Dispatcher

  defmodule BinaryResource do
    use Resource, name: "binary", mime_type: "application/octet-stream"
    def read(request), do: {:ok, request.assigns.content}
  end

  defmodule Catalog do
    use Portico.Server, name: "binary", version: "1"
    resource "company://sample", BinaryResource
    resource_template "company://sample/{id}", BinaryResource
  end

  test "constructor accepts arbitrary and empty bytes and rejects non-binaries" do
    for bytes <- [<<0, 255, 1>>, "", "hello"] do
      assert {:ok, %Resource{blob: ^bytes, text: nil}} = Resource.blob(bytes)
    end

    for value <- [nil, :bad, 42, [0, 255], %{}, <<1::1>>] do
      assert Resource.blob(value) == {:error, :invalid_blob}
    end
  end

  test "helpers preserve bytes; protocol encodes only blob with concrete URI and MIME" do
    for uri <- ["company://sample", "company://sample/one"],
        bytes <- [<<0, 255, 1>>, ""] do
      {:ok, content} = Resource.blob(bytes)
      assigns = %{content: %{content | uri: "company://forged", mime_type: "text/plain"}}
      assert {:ok, result} = Test.read_resource(Catalog, uri, assigns: assigns)
      assert result.blob == bytes
      assert result.text == nil
      assert result.uri == uri
      assert result.mime_type == "application/octet-stream"

      {:reply, reply} = Dispatcher.dispatch(Catalog, message(uri), assigns)

      assert reply["result"]["contents"] == [
               %{
                 "uri" => uri,
                 "mimeType" => "application/octet-stream",
                 "blob" => Base.encode64(bytes)
               }
             ]

      assert reply["result"]["cacheScope"] == "private"
      assert reply["result"]["ttlMs"] == 0
    end
  end

  test "malformed or conflicting payloads fail as tuples and sanitized protocol errors" do
    for content <- [
          %Resource{},
          %Resource{blob: :bad},
          %Resource{text: "text", blob: <<1>>},
          %Resource{text: "", blob: ""},
          %Resource{text: <<255>>}
        ] do
      assert Test.read_resource(Catalog, "company://sample", assigns: %{content: content}) ==
               {:error, :invalid_resource}

      assert {:reply, %{"error" => %{"code" => -32603, "message" => "Internal error"}}} =
               Dispatcher.dispatch(Catalog, message("company://sample"), %{content: content})
    end
  end

  defp message(uri) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "resources/read",
      "params" => %{
        "uri" => uri,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end
end
