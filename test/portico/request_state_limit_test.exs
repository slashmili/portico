defmodule Portico.RequestStateLimitTest do
  use ExUnit.Case, async: true
  alias Portico.{Elicitation, Input, Request}

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}

    @impl true
    def call(_, _) do
      {:ok, form} =
        Input.form("Continue?", schema: %{type: "object", properties: %{yes: %{type: "boolean"}}})

      {:ok, form, String.duplicate("x", 64_000)}
    end

    @impl true
    def handle_input(_, _, _), do: {:error, :unexpected_resume}
  end

  defmodule Server do
    use Portico.Server, name: "state-limit", version: "1"
    tool "large", Tool
  end

  setup do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("k", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    {:ok, form} =
      Input.form("Continue?", schema: %{type: "object", properties: %{yes: %{type: "boolean"}}})

    %{form: form, request: %Request{server: Server, tool_name: "large", arguments: %{}}}
  end

  defp limit(value) do
    Application.put_env(:portico, Server,
      elicitation_key: String.duplicate("k", 32),
      max_request_state_bytes: value
    )
  end

  test "default bounds final encoded tokens and helpers preserve the reason", %{
    form: form,
    request: request
  } do
    assert {:ok, _} = Elicitation.seal(form, "small", request)

    assert {:error, :request_state_too_large} =
             Elicitation.seal(form, String.duplicate("x", 64_000), request)

    context = %Portico.Test.Context{
      server: Server,
      client_capabilities: %{"elicitation" => %{"form" => %{}}}
    }

    assert {:error, :request_state_too_large} = Portico.Test.call_tool(context, "large", %{})
  end

  test "configured byte boundary is inclusive and overrides the default", %{
    form: form,
    request: request
  } do
    {:ok, token} = Elicitation.seal(form, "state", request)
    size = byte_size(token)
    limit(size)
    assert {:ok, token} = Elicitation.seal(form, "state", request)
    assert byte_size(token) == size
    limit(size - 1)
    assert {:error, :request_state_too_large} = Elicitation.seal(form, "state", request)
    # Lowering the generation limit doesn't invalidate already-issued tokens.
    assert {:ok, "state"} = Elicitation.verify(token, request)
    limit(128_000)
    assert {:ok, large} = Elicitation.seal(form, String.duplicate("x", 64_000), request)
    assert byte_size(large) > 64_000 and byte_size(large) <= 128_000
  end

  test "form definitions and sampling text count toward the limit", %{
    form: form,
    request: request
  } do
    large = String.duplicate("x", 64_000)

    assert {:error, :request_state_too_large} =
             Elicitation.seal(%{form | message: large}, "state", request)

    {:ok, sample} = Input.sample(large, max_tokens: 10)
    assert {:error, :request_state_too_large} = Elicitation.seal(sample, "state", request)
    {:ok, url} = Input.url("Approve", url: "https://example.com/approve")
    assert {:error, :request_state_too_large} = Elicitation.seal(url, large, request)

    resource = %{
      request
      | tool_name: nil,
        arguments: nil,
        resource_uri: "company://report",
        resource_route: "company://report"
    }

    assert {:error, :request_state_too_large} = Elicitation.seal(form, large, resource)
  end

  test "invalid runtime limits return tuples", %{form: form, request: request} do
    for value <- [nil, 0, -1, 64_000.0, "64000", :infinity] do
      limit(value)
      assert {:error, :invalid_request_state_limit} = Elicitation.seal(form, "state", request)
    end
  end
end
