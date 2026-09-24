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

  test "text appends in order while preserving the original result and error flag" do
    original = Result.error("first")
    result = original |> Result.text("Grüße\n") |> Result.text("")

    assert result.content == [
             %{type: "text", text: "first"},
             %{type: "text", text: "Grüße\n"},
             %{type: "text", text: ""}
           ]

    assert result.is_error
    assert original == Result.error("first")
    assert Result.text(%Result{}, "first") == Result.text("first")
  end

  test "put_error sets and clears the flag without changing content" do
    original = Result.text("message")
    failure = Result.put_error(original, true)
    assert failure == Result.error("message")
    assert Result.put_error(failure, false) == original
    assert Result.put_error(failure, true) == failure
    refute original.is_error
  end

  test "text append validates the new text and requires a result" do
    for value <- [nil, 42, :ok, %{}] do
      assert_raise FunctionClauseError, fn -> Result.text(%Result{}, value) end
    end

    assert_raise ArgumentError, fn -> Result.text(%Result{}, <<255>>) end
    assert_raise FunctionClauseError, fn -> apply(Result, :text, [%{}, "hello"]) end
  end

  test "put_error requires a result and a boolean" do
    for value <- [nil, 1, "true", :error] do
      assert_raise FunctionClauseError, fn -> Result.put_error(%Result{}, value) end
    end

    assert_raise FunctionClauseError, fn -> apply(Result, :put_error, [%{}, true]) end
  end
end
