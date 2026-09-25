defmodule Portico.ResultTest do
  use ExUnit.Case, async: true
  alias Portico.Result
  doctest Result

  test "structured content normalizes JSON values and includes a matching text fallback" do
    for {input, expected} <- [
          {%{sum: 5, nested: [%{ok: true}, nil]},
           %{"sum" => 5, "nested" => [%{"ok" => true}, nil]}},
          {[], []},
          {%{}, %{}},
          {[1, 2.5, false], [1, 2.5, false]},
          {"日本語", "日本語"},
          {1, 1},
          {2.5, 2.5},
          {true, true},
          {false, false},
          {nil, nil}
        ] do
      assert {:ok, result} = Result.structured(input)
      assert result.structured_content == expected
      assert [%{type: "text", text: json}] = result.content
      assert JSON.decode!(json) == expected
      assert {:ok, updated} = result |> Result.text("Commentary") |> Result.put_error(true)
      assert updated.structured_content == expected
      assert updated.is_error
    end
  end

  test "structured content rejects invalid data recursively with error tuples" do
    for value <- [
          :not_set,
          :ok,
          self(),
          fn -> :ok end,
          {1, 2},
          %Result{},
          <<255>>,
          %{1 => "value"},
          %{<<255>> => 1},
          %{"sum" => 1, sum: 2},
          [%{nested: :invalid}],
          %{nested: %{"a" => 1, a: 2}},
          [1 | 2],
          [1 | %{}]
        ] do
      assert Result.structured(value) == {:error, :invalid_structured_content}
    end
  end

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
