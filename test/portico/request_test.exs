defmodule Portico.RequestTest do
  use ExUnit.Case, async: true

  alias Portico.Request

  doctest Request

  test "a new request has no application assigns" do
    assert %Request{}.assigns == %{}
  end

  test "assign adds application context without changing the original request" do
    request = %Request{assigns: %{locale: "en"}}
    user = %{id: 42}

    updated = Request.assign(request, :current_user, user)

    assert %Request{assigns: %{locale: "en", current_user: ^user}} = updated
    assert request.assigns == %{locale: "en"}
  end

  test "assign replaces an existing value" do
    request = %Request{assigns: %{locale: "en"}}

    assert Request.assign(request, :locale, "de").assigns == %{locale: "de"}
  end

  test "assign rejects non-atom keys without raising" do
    for key <- ["current_user", 42, [], %{}] do
      assert Request.assign(%Request{}, key, :value) == {:error, :invalid_assign_key}
    end
  end

  test "assign rejects invalid requests before inspecting the key" do
    for request <- [nil, :request, [], %{}, %{assigns: %{}}] do
      assert Request.assign(request, "bad key", :value) == {:error, :invalid_request}
    end
  end

  test "assign rejects malformed existing assigns before inspecting the key" do
    for assigns <- [nil, [], :invalid, %Request{}, %{"locale" => "en"}, %{"bad" => 2, ok: 1}] do
      request = %Request{assigns: assigns}
      assert Request.assign(request, :locale, "de") == {:error, :invalid_assigns}
      assert Request.assign(request, "locale", "de") == {:error, :invalid_assigns}
    end
  end

  test "successful pipelines preserve metadata and allow arbitrary assign values" do
    request = %Request{id: 7, method: "tools/call", progress_token: "progress"}
    value = {self(), fn -> :ok end}
    updated = request |> Request.assign(:context, value) |> Request.assign(:locale, "en")

    assert updated == %{request | assigns: %{context: value, locale: "en"}}
    assert request.assigns == %{}
  end
end
