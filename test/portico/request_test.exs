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

  test "assign requires an atom key" do
    assert_raise FunctionClauseError, fn ->
      # Exercise runtime rejection without a static type warning on Elixir 1.20.
      apply(Request, :assign, [%Request{}, "current_user", %{id: 42}])
    end
  end
end
