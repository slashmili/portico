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
