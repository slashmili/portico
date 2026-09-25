defmodule Portico.ResultTest do
  use ExUnit.Case, async: true
  alias Portico.Result
  doctest Result

  test "text returns a tuple and preserves empty text, Unicode and line breaks" do
    for text <- ["", "Grüße 👋\nSecond line\n"] do
      assert Result.text(text) == {:ok, %Result{content: [%{type: "text", text: text}]}}
    end
  end

  test "text and error reject invalid text without exceptions" do
    for value <- [nil, 42, :ok, ~c"hello", %{text: "hello"}, <<255>>] do
      assert Result.text(value) == {:error, :invalid_text}
      assert Result.error(value) == {:error, :invalid_text}
      assert Result.text(%Result{}, value) == {:error, :invalid_text}
    end
  end

  test "error constructs a completed tool failure rather than a constructor failure" do
    assert {:ok, result} = Result.error("Try again")
    assert result.is_error
    assert result.content == [%{type: "text", text: "Try again"}]
  end

  test "text appends to structs and success tuples without changing originals" do
    {:ok, original} = Result.error("first")
    assert {:ok, result} = original |> Result.text("Grüße\n") |> Result.text("")

    assert result.content == [
             %{type: "text", text: "first"},
             %{type: "text", text: "Grüße\n"},
             %{type: "text", text: ""}
           ]

    assert result.is_error
    assert {:ok, original} == Result.error("first")
    assert Result.text(%Result{}, "first") == Result.text("first")
  end

  test "put_error sets and clears the flag on structs and success tuples" do
    {:ok, original} = Result.text("message")
    failure = Result.put_error(original, true)
    assert failure == Result.error("message")
    assert Result.put_error(failure, false) == {:ok, original}
    assert Result.put_error(failure, true) == failure
    refute original.is_error
  end

  test "invalid result containers and error flags return reasons" do
    for value <- [nil, %{}, %Result{content: nil}, {:ok, "wrong"}] do
      assert Result.text(value, "hello") == {:error, :invalid_result}
      assert Result.put_error(value, true) == {:error, :invalid_result}
    end

    for value <- [nil, 1, "true", :error] do
      assert Result.put_error(%Result{}, value) == {:error, :invalid_error_flag}
    end
  end

  test "pipelines preserve the first error without raising or overwriting it" do
    assert Result.text(42) |> Result.text("next") |> Result.put_error(true) ==
             {:error, :invalid_text}

    assert Result.text("ok") |> Result.put_error(nil) |> Result.text("next") ==
             {:error, :invalid_error_flag}

    assert Result.text(%{}, "text") |> Result.put_error(true) == {:error, :invalid_result}
  end
end
