defmodule Portico.Transport.HeadersTest do
  use ExUnit.Case, async: true
  alias Portico.Transport.Headers

  @request %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "tools/call",
    "params" => %{
      "name" => "add",
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }
  }
  @headers [
    {"mcp-protocol-version", "2026-07-28"},
    {"mcp-method", "tools/call"},
    {"mcp-name", "add"}
  ]

  test "matches standard headers case-insensitively by name" do
    assert Headers.validate(@headers, @request) == :ok

    assert Headers.validate(
             Enum.map(@headers, fn {key, value} -> {String.upcase(key), value} end),
             @request
           ) == :ok

    assert Headers.validate([{"authorization", "ignored"} | @headers], @request) == :ok
  end

  test "requires exactly one of each applicable standard header" do
    for {key, value} <- @headers do
      assert Headers.validate(List.keydelete(@headers, key, 0), @request) ==
               {:error, :header_mismatch}

      assert Headers.validate([{String.upcase(key), value} | @headers], @request) ==
               {:error, :header_mismatch}
    end
  end

  test "values are case-sensitive and must match the body" do
    for {key, _} <- @headers do
      assert Headers.validate(List.keyreplace(@headers, key, 0, {key, "different"}), @request) ==
               {:error, :header_mismatch}
    end

    assert Headers.validate(
             List.keyreplace(@headers, "mcp-name", 0, {"mcp-name", "ADD"}),
             @request
           ) ==
             {:error, :header_mismatch}
  end

  test "discovery and listing do not require a name header" do
    for method <- ["server/discover", "tools/list"] do
      request = %{
        @request
        | "method" => method,
          "params" => Map.delete(@request["params"], "name")
      }

      headers = [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", method}]
      assert Headers.validate(headers, request) == :ok
    end
  end

  test "standard named methods use their specified body field" do
    for {method, field} <- [{"resources/read", "uri"}, {"prompts/get", "name"}] do
      request = @request |> Map.put("method", method) |> put_in(["params", field], "example")

      headers = [
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", method},
        {"mcp-name", "example"}
      ]

      assert Headers.validate(headers, request) == :ok
    end
  end

  test "decodes Base64 names exactly once, preserving Unicode, whitespace, and literal sentinels" do
    for name <- ["日本語", " padded ", "line1\nline2", "=?base64?literal?=", "add"] do
      request = put_in(@request, ["params", "name"], name)

      headers =
        List.keyreplace(
          @headers,
          "mcp-name",
          0,
          {"mcp-name", "=?base64?#{Base.encode64(name)}?="}
        )

      assert Headers.validate(headers, request) == :ok
    end
  end

  test "rejects unsafe unencoded names even if they match the body" do
    for name <- ["日本語", " padded ", "line1\nline2", <<0>>, <<127>>, <<255>>] do
      headers = List.keyreplace(@headers, "mcp-name", 0, {"mcp-name", name})

      assert Headers.validate(headers, put_in(@request, ["params", "name"], name)) ==
               {:error, :header_mismatch}
    end
  end

  test "rejects invalid Base64, invalid decoded UTF-8, and decoded mismatches" do
    for name <- ["=?base64?%%%?=", "=?base64?/w==?=", "=?base64?b3RoZXI=?="] do
      headers = List.keyreplace(@headers, "mcp-name", 0, {"mcp-name", name})
      assert Headers.validate(headers, @request) == {:error, :header_mismatch}
    end
  end

  test "does not accept unsafe method or version header values" do
    for {header, path} <- [
          {"mcp-method", ["method"]},
          {"mcp-protocol-version", ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]}
        ] do
      headers = List.keyreplace(@headers, header, 0, {header, " invalid "})

      assert Headers.validate(headers, put_in(@request, path, " invalid ")) ==
               {:error, :header_mismatch}
    end
  end

  test "encodes header mismatch as the reserved MCP protocol error" do
    assert Portico.Protocol.Error.response(:header_mismatch, 1) == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "error" => %{"code" => -32020, "message" => "Header mismatch"}
           }
  end
end
