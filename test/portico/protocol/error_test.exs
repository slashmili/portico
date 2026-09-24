defmodule Portico.Protocol.ErrorTest do
  use ExUnit.Case, async: true

  alias Portico.Protocol.Error

  test "encodes invalid request with a known request ID" do
    assert Error.response(:invalid_request, "request-1") == %{
             "jsonrpc" => "2.0",
             "id" => "request-1",
             "error" => %{"code" => -32600, "message" => "Invalid request"}
           }
  end

  test "encodes invalid params separately from a completed tool result" do
    assert Error.response(:invalid_params, 42) == %{
             "jsonrpc" => "2.0",
             "id" => 42,
             "error" => %{"code" => -32602, "message" => "Invalid params"}
           }
  end

  test "omits an unknown ID instead of encoding null" do
    expected = %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32600, "message" => "Invalid request"}
    }

    assert Error.response(:invalid_request) == expected
    assert Error.response(:invalid_request, nil) == expected
  end

  test "preserves valid IDs through JSON encoding and decoding" do
    for id <- [0, -1, 42, "", "42", "日本語"] do
      response = Error.response(:invalid_params, id)
      assert response["id"] === id
      assert response |> JSON.encode!() |> JSON.decode!() == response
    end
  end

  test "rejects invalid IDs rather than reflecting them into a response" do
    for id <- [true, false, 1.0, [], %{}, :request, <<255>>] do
      assert_raise ArgumentError,
                   "expected a string or integer request ID, or nil when unknown",
                   fn ->
                     Error.response(:invalid_request, id)
                   end
    end
  end

  test "does not silently turn unsupported error reasons into a wire error" do
    assert_raise FunctionClauseError, fn ->
      apply(Error, :response, [:unknown_reason, 1])
    end
  end
end
