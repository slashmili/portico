defmodule Portico.ResultTest do
  use ExUnit.Case, async: true

  alias Portico.Result

  doctest Result

  test "text returns one content item and preserves Unicode and line breaks" do
    text = "Grüße 👋\nSecond line\n"

    assert Result.text(text) == %Result{content: [%{type: "text", text: text}]}
  end

  test "text accepts an empty string" do
    assert Result.text("") == %Result{content: [%{type: "text", text: ""}]}
  end

  test "text rejects values that are not binaries" do
    for value <- [nil, 42, :ok, ~c"hello", %{text: "hello"}] do
      assert_raise FunctionClauseError, fn ->
        apply(Result, :text, [value])
      end
    end
  end

  test "text rejects invalid UTF-8" do
    assert_raise ArgumentError, "expected text to be a valid UTF-8 string", fn ->
      Result.text(<<255>>)
    end
  end
end
