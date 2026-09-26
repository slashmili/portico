defmodule Portico.Protocol.MetadataTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Validation

  @version "io.modelcontextprotocol/protocolVersion"
  @capabilities "io.modelcontextprotocol/clientCapabilities"
  @client "io.modelcontextprotocol/clientInfo"
  @meta %{@version => "2026-07-28", @capabilities => %{}}

  test "accepts required metadata without optional client information" do
    assert Validation.request_metadata(%{"_meta" => @meta}) == {:ok, @meta}
  end

  test "preserves client information, capabilities, and extra metadata" do
    meta =
      Map.merge(@meta, %{
        @client => %{"name" => "test-client", "version" => "dev", "title" => "Test Client"},
        @capabilities => %{"elicitation" => %{"form" => %{}}, "com.example/custom" => %{}},
        "com.example/trace" => "abc"
      })

    assert Validation.request_metadata(%{"_meta" => meta, "name" => "add"}) == {:ok, meta}
  end

  test "preserves valid metadata names, prefixes and opaque extension data" do
    for key <- [
          "",
          "a",
          "0",
          "A0",
          "a-b_c.d",
          "com.example/trace",
          "a/x",
          "a/",
          "A.B2-C/name",
          "io.modelcontextprotocol/future",
          "dev.mcp/future",
          "com.example.mcp/custom"
        ] do
      meta = Map.put(@meta, key, %{"not a metadata key/!" => [nil, true]})
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end

    meta =
      Map.merge(@meta, %{
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
        "tracestate" => "vendor=value",
        "baggage" => "key=value"
      })

    assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
  end

  test "rejects malformed metadata names and prefixes" do
    for key <- [
          "bad key",
          "_name",
          "name_",
          ".name",
          "name.",
          "-name",
          "name-",
          "/name",
          "/",
          "com..example/name",
          ".com/name",
          "com./name",
          "1com/name",
          "com.1example/name",
          "-com/name",
          "com-/name",
          "com.ex_ample/name",
          "com.example/a/b",
          "com.example/名",
          "名/name",
          "x\n",
          "x\r",
          "x\t",
          "x\0",
          <<255>>
        ] do
      meta = Map.put(@meta, key, "opaque")
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "accepts all protocol log levels unchanged and permits omission" do
    assert Validation.request_metadata(%{"_meta" => @meta}) == {:ok, @meta}

    for level <- ~w(debug info notice warning error critical alert emergency) do
      meta = Map.put(@meta, "io.modelcontextprotocol/logLevel", level)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end
  end

  test "rejects invalid log levels without coercion" do
    for level <- [nil, false, 42, [], %{}, :info, <<255>>, "", "verbose", "warn", "INFO", "info "] do
      meta = Map.put(@meta, "io.modelcontextprotocol/logLevel", level)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "requires metadata and both required fields on every request" do
    assert Validation.request_metadata(%{"_meta" => @meta}) == {:ok, @meta}

    for params <- [
          %{},
          %{"_meta" => %{}},
          %{"_meta" => Map.delete(@meta, @version)},
          %{"_meta" => Map.delete(@meta, @capabilities)}
        ] do
      assert Validation.request_metadata(params) == {:error, :invalid_params}
    end
  end

  test "rejects invalid params and metadata containers" do
    for value <- [nil, [], "metadata", 1, %Portico.Request{}, %{atom_key: true}] do
      assert Validation.request_metadata(value) == {:error, :invalid_params}
      assert Validation.request_metadata(%{"_meta" => value}) == {:error, :invalid_params}
    end
  end

  test "requires a string protocol version without choosing supported versions" do
    for version <- ["2026-07-28", "future-version"] do
      meta = Map.put(@meta, @version, version)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end

    for version <- [nil, 2026, [], %{}, :current, <<255>>] do
      assert Validation.request_metadata(%{"_meta" => Map.put(@meta, @version, version)}) ==
               {:error, :invalid_params}
    end
  end

  test "capabilities must be a string-keyed object, even when empty" do
    for capabilities <- [nil, false, [], "tools", %Portico.Request{}, %{elicitation: %{}}] do
      assert Validation.request_metadata(%{
               "_meta" => Map.put(@meta, @capabilities, capabilities)
             }) ==
               {:error, :invalid_params}
    end
  end

  test "preserves known capability declarations and opaque settings" do
    for capabilities <- [
          %{"roots" => %{}, "sampling" => %{}, "experimental" => %{}, "extensions" => %{}},
          %{
            "roots" => %{"future" => true},
            "sampling" => %{
              "tools" => %{},
              "context" => %{"future" => [nil, true]},
              "future" => 1
            },
            "experimental" => %{"not a metadata name/!" => %{"opaque key" => []}},
            "extensions" => %{
              "com.example/feature" => %{"opaque key/!" => true},
              "io.modelcontextprotocol/future" => %{},
              "a/" => %{}
            },
            "unknown capability" => ["preserved"]
          }
        ] do
      meta = Map.put(@meta, @capabilities, capabilities)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end
  end

  test "rejects malformed known capability containers and settings" do
    for value <- [nil, true, [], 42, "yes", %Portico.Request{}, %{atom: true}],
        capabilities <- [
          %{"roots" => value},
          %{"sampling" => value},
          %{"sampling" => %{"tools" => value}},
          %{"sampling" => %{"context" => value}},
          %{"experimental" => value},
          %{"experimental" => %{"test" => value}},
          %{"extensions" => value},
          %{"extensions" => %{"com.example/test" => value}}
        ] do
      meta = Map.put(@meta, @capabilities, capabilities)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "extension identifiers require a valid prefix but experimental names do not" do
    for key <- [
          "",
          "feature",
          "/feature",
          "com..example/feature",
          "1com/feature",
          "com.example/a/b",
          "com.example/bad key",
          <<255>>
        ] do
      meta = Map.put(@meta, @capabilities, %{"extensions" => %{key => %{}}})
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "preserves valid elicitation modes and unknown capability fields" do
    for elicitation <- [
          %{},
          %{"form" => %{}},
          %{"url" => %{}},
          %{"form" => %{}, "url" => %{}},
          %{"form" => %{"com.example/options" => [1, true, nil]}, "com.example/future" => true},
          %{"com.example/future" => %{}}
        ] do
      capabilities = %{"elicitation" => elicitation, "com.example/custom" => ["opaque"]}
      meta = Map.put(@meta, @capabilities, capabilities)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end
  end

  test "rejects malformed elicitation objects and either malformed mode" do
    for invalid <- [
          nil,
          false,
          true,
          [],
          "form",
          42,
          %Portico.Request{},
          %{atom: true},
          %{<<255>> => true}
        ],
        elicitation <- [
          invalid,
          %{"form" => invalid},
          %{"url" => invalid},
          %{"form" => %{}, "url" => invalid}
        ] do
      meta = Map.put(@meta, @capabilities, %{"elicitation" => elicitation})
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "preserves complete client information and icon extensions" do
    for icons <- [
          [],
          [%{"src" => "https://example.invalid/icon.png"}],
          [
            %{
              "src" => "data:image/png;base64,AAAA",
              "mimeType" => "image/png",
              "sizes" => ["48x48", "any"],
              "theme" => "dark",
              "com.example/icon" => true
            },
            %{"src" => "https://example.invalid/light.svg", "sizes" => [], "theme" => "light"}
          ]
        ] do
      info = %{
        "name" => "client",
        "version" => "1",
        "title" => "日本語",
        "description" => "",
        "websiteUrl" => "https://example.invalid",
        "icons" => icons,
        "com.example/custom" => [nil, true]
      }

      meta = Map.put(@meta, @client, info)
      assert Validation.request_metadata(%{"_meta" => meta}) == {:ok, meta}
    end
  end

  test "rejects malformed optional client information without exceptions" do
    info = %{"name" => "client", "version" => "1"}

    for key <- ["title", "description", "websiteUrl"],
        value <- [nil, false, 42, [], %{}, <<255>>] do
      meta = Map.put(@meta, @client, Map.put(info, key, value))
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end

    for icons <- [
          nil,
          false,
          %{},
          "icon",
          [nil],
          [%{}],
          [%Portico.Request{}],
          [%{"src" => 42}],
          [%{"src" => <<255>>}],
          [%{"src" => "x", :extra => true}],
          [%{"src" => "x", "mimeType" => nil}],
          [%{"src" => "x", "mimeType" => <<255>>}],
          [%{"src" => "x", "sizes" => "any"}],
          [%{"src" => "x", "sizes" => [42]}],
          [%{"src" => "x", "sizes" => [<<255>>]}],
          [%{"src" => "x", "sizes" => ["any" | 1]}],
          [%{"src" => "x", "theme" => "auto"}],
          [%{"src" => "x", "theme" => nil}],
          [%{"src" => "x"} | 1]
        ] do
      meta = Map.put(@meta, @client, Map.put(info, "icons", icons))
      assert Validation.request_metadata(%{"_meta" => meta}) == {:error, :invalid_params}
    end
  end

  test "optional client information requires string name and version when supplied" do
    for client <- [
          nil,
          [],
          "client",
          %{},
          %{"name" => "client"},
          %{"version" => "1"},
          %{"name" => 42, "version" => "1"},
          %{"name" => "client", "version" => nil},
          %{"name" => <<255>>, "version" => "1"},
          %{name: "client", version: "1"}
        ] do
      assert Validation.request_metadata(%{"_meta" => Map.put(@meta, @client, client)}) ==
               {:error, :invalid_params}
    end
  end
end
