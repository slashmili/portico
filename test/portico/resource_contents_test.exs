defmodule Portico.ResourceContentsTest do
  use ExUnit.Case, async: true
  alias Portico.{Resource, Test}
  alias Portico.Protocol.Dispatcher

  defmodule Directory do
    use Resource, name: "directory", mime_type: "inode/directory"
    def read(request), do: {:ok, request.assigns.contents}
  end

  defmodule Catalog do
    use Portico.Server, name: "contents", version: "1"
    resource "company://docs", Directory
    resource_template "company://docs/{section}", Directory
  end

  test "constructors validate optional metadata without raising" do
    for constructor <- [&Resource.text/2, &Resource.blob/2] do
      assert {:ok, %{uri: "company://docs/a", mime_type: "text/plain"}} =
               constructor.("", uri: "company://docs/a", mime_type: "text/plain")

      for {options, reason} <- [
            {%{}, :invalid_options},
            {[uri: "company://a", uri: "company://b"], :invalid_options},
            {[unknown: true], :invalid_options},
            {[uri: nil], :invalid_uri},
            {[uri: "relative"], :invalid_uri},
            {[mime_type: nil], :invalid_mime_type},
            {[mime_type: <<255>>], :invalid_mime_type}
          ] do
        assert constructor.("", options) == {:error, reason}
      end
    end
  end

  test "mixed lists preserve order and item metadata without inheriting route MIME" do
    {:ok, text} = Resource.text("Welcome", uri: "company://docs/readme", mime_type: "text/plain")
    {:ok, blob} = Resource.blob(<<255>>, uri: "company://docs/data")
    contents = [text, blob]

    for uri <- ["company://docs", "company://docs/section"] do
      assert Test.read_resource(Catalog, uri, assigns: %{contents: contents}) == {:ok, contents}
      {:reply, reply} = Dispatcher.dispatch(Catalog, message(uri), %{contents: contents})

      assert reply["result"]["contents"] == [
               %{"uri" => text.uri, "mimeType" => "text/plain", "text" => "Welcome"},
               %{"uri" => blob.uri, "blob" => "/w=="}
             ]

      assert reply["result"]["cacheScope"] == "private"
      assert reply["result"]["ttlMs"] == 0
    end
  end

  test "empty and singleton lists retain list return shape" do
    {:ok, text} = Resource.text("", uri: "company://docs/empty")

    for contents <- [[], [text]] do
      assert Test.read_resource(Catalog, "company://docs", assigns: %{contents: contents}) ==
               {:ok, contents}

      {:reply, reply} =
        Dispatcher.dispatch(Catalog, message("company://docs"), %{contents: contents})

      assert length(reply["result"]["contents"]) == length(contents)
    end
  end

  test "one invalid item rejects the whole list without leaking partial content" do
    {:ok, valid} = Resource.text("private", uri: "company://docs/private")

    for invalid <- [
          nil,
          "bad",
          %Resource{text: "missing URI"},
          %Resource{uri: "relative", text: "x"},
          %Resource{uri: "company://a", text: "x", mime_type: 1},
          %Resource{uri: "company://a", text: <<255>>},
          %Resource{uri: "company://a", text: "x", blob: ""}
        ] do
      assigns = %{contents: [valid, invalid]}

      assert Test.read_resource(Catalog, "company://docs", assigns: assigns) ==
               {:error, :invalid_resource}

      {:reply, reply} = Dispatcher.dispatch(Catalog, message("company://docs"), assigns)
      assert reply["error"] == %{"code" => -32603, "message" => "Internal error"}
      refute Map.has_key?(reply, "result")
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
