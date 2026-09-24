defmodule Portico.Protocol.ValidationTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Validation

  @request %{
    "jsonrpc" => "2.0",
    "id" => "request-1",
    "method" => "tools/call",
    "params" => %{"name" => "add", "arguments" => %{"a" => 2, "b" => 3}}
  }

  test "accepts string and integer IDs without changing their values" do
    for id <- ["request-1", "", "日本語", 0, -1, 42] do
      message = %{@request | "id" => id}
      assert Validation.envelope(message) == {:ok, :request, message}
    end
  end

  test "rejects malformed IDs, including explicit null and integral floats" do
    for id <- [nil, true, false, 1.0, 1.5, [], %{}, :request, <<255>>] do
      assert Validation.envelope(%{@request | "id" => id}) == {:error, :invalid_request}
    end
  end

  test "an absent ID marks a notification and is distinct from a null ID" do
    message = Map.delete(@request, "id")
    assert Validation.envelope(message) == {:ok, :notification, message}
    assert Validation.envelope(Map.put(message, "id", nil)) == {:error, :invalid_request}
  end

  test "params may be absent or an object, but not null or an array" do
    message = Map.delete(@request, "params")
    assert Validation.envelope(message) == {:ok, :request, message}

    for params <- [%{}, %{"_meta" => %{}}] do
      message = %{@request | "params" => params}
      assert Validation.envelope(message) == {:ok, :request, message}
    end

    for params <- [nil, [], [1], "params", 42, %Portico.Request{}, %{name: "add"}] do
      assert Validation.envelope(%{@request | "params" => params}) == {:error, :invalid_request}
    end
  end

  test "requires the JSON-RPC 2.0 version and a string method" do
    for message <- [
          Map.delete(@request, "jsonrpc"),
          %{@request | "jsonrpc" => "1.0"},
          %{@request | "jsonrpc" => 2.0},
          Map.delete(@request, "method"),
          %{@request | "method" => nil},
          %{@request | "method" => :add},
          %{@request | "method" => <<255>>}
        ] do
      assert Validation.envelope(message) == {:error, :invalid_request}
    end
  end

  test "does not perform method lookup or discard extension fields" do
    message = @request |> Map.put("method", "future/method") |> Map.put("extension", true)
    assert Validation.envelope(message) == {:ok, :request, message}
  end

  test "only accepts a single object with string keys" do
    for message <- [
          nil,
          42,
          "{}",
          [],
          [@request],
          %Portico.Request{},
          %{jsonrpc: "2.0", id: 1, method: "tools/call"},
          Map.put(@request, :extra, true),
          Map.put(@request, <<255>>, true)
        ] do
      assert Validation.envelope(message) == {:error, :invalid_request}
    end
  end

  test "applies envelope checks to notifications too" do
    message = @request |> Map.delete("id") |> Map.put("params", [])
    assert Validation.envelope(message) == {:error, :invalid_request}
  end
end
