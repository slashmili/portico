defmodule Portico.URLInputTest do
  use ExUnit.Case, async: true
  alias Portico.Input

  test "builds URL requests without fetching the destination" do
    for url <- [
          "https://example.invalid/connect?flow=123",
          "http://localhost:4000/connect",
          "https://[::1]/connect"
        ] do
      assert {:ok, input} = Input.url("Connect account", url: url)
      assert input.mode == :url
      assert input.url == url
      assert input.schema == nil
    end
  end

  test "invalid messages, options and unsafe or malformed URLs return tuples" do
    assert Input.url(nil, url: "https://example.com") == {:error, :invalid_message}

    for options <- [
          %{},
          [],
          [url: "https://example.com", url: "https://other.com"],
          [schema: %{}]
        ] do
      assert Input.url("Connect", options) == {:error, :invalid_options}
    end

    for url <- [
          nil,
          1,
          "",
          "/connect",
          "//example.com/connect",
          "javascript:alert(1)",
          "file:///tmp/key",
          "https://",
          "https://user:pass@example.com",
          "https://example.com/a b",
          "https://example.com/\n",
          "https://example.com/%zz",
          "https://example.com:bad",
          <<255>>
        ] do
      assert Input.url("Connect", url: url) == {:error, :invalid_url}
    end
  end
end
