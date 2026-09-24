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

  test "error builds an explicit tool failure with text content" do
    for text <- ["", "Unable to complete: Grüße\nTry again"] do
      result = Result.error(text)
      assert result.is_error == true
      assert result.content == [%{type: "text", text: text}]
    end

    assert Result.text("ok").is_error == false
  end

  test "error rejects non-text values and invalid UTF-8" do
    for value <- [nil, 42, :error, %{}] do
      assert_raise FunctionClauseError, fn -> Result.error(value) end
    end

    assert_raise ArgumentError, fn -> Result.error(<<255>>) end
  end
end
