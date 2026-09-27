defmodule Portico.ElicitationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Portico.{Input, Result, Request}
  alias Portico.Protocol.Elicitation
  alias Portico.Test.Context

  defmodule Verifier do
    def verify(token, request) do
      send(request.assigns.observer, :verified)

      with {:ok, state} <- Portico.Elicitation.verify(token, request) do
        case request.assigns[:verifier_mode] do
          :reject -> {:error, :denied}
          :bad -> :bad
          :raise -> raise "verifier failed"
          _ -> {:ok, "verified:" <> state}
        end
      end
    end
  end

  defmodule Tool do
    use Portico.Tool, input_schema: %{type: "object"}, elicitation_verifier: &Verifier.verify/2
    @impl true
    def call(_, _) do
      {:ok, form} =
        Input.form("Name?",
          schema: %{
            type: "object",
            properties: %{name: %{type: "string", minLength: 1}},
            required: ["name"]
          }
        )

      {:ok, form, "application-state"}
    end

    @impl true
    def handle_input(answer, state, request) do
      send(request.assigns.observer, {:handled, answer, state, request.assigns})
      Result.text("done")
    end
  end

  defmodule Default do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(args, request), do: Tool.call(args, request)
    @impl true
    def handle_input(answer, state, request), do: Tool.handle_input(answer, state, request)
  end

  defmodule Missing do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(_, request), do: Tool.call(%{}, request)
  end

  defmodule Server do
    use Portico.Server, name: "elicitation", version: "1"
    tool "work", Tool
    tool "missing", Missing
    tool "other", Tool
    tool "default", Default
  end

  setup do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("k", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    %{
      mcp: %Context{
        server: Server,
        client_capabilities: %{"elicitation" => %{"form" => %{}}},
        assigns: %{observer: self()}
      }
    }
  end

  defp resume(mcp, state, response, options \\ []) do
    Portico.Test.call_tool(
      mcp,
      "work",
      %{},
      Keyword.merge([request_state: state, input_responses: %{"form" => response}], options)
    )
  end

  test "the default verifier restores the application state", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "default", %{})

    assert {:ok, %Result{}} =
             Portico.Test.call_tool(mcp, "default", %{},
               request_state: token,
               input_responses: %{"form" => %{"action" => "cancel"}}
             )

    assert_received {:handled, :cancel, "application-state", _}
    refute Map.has_key?(Default.__portico_tool__(), :elicitation_verifier)
  end

  test "changing the key rejects old replies with both default and custom verifiers", %{mcp: mcp} do
    pending =
      for tool <- ["default", "work"] do
        {:ok, _, token} = Portico.Test.call_tool(mcp, tool, %{})
        {tool, token}
      end

    # Restarting the listener or recompiling code does not change application
    # configuration. Both tokens remain valid with the original key.
    for {tool, token} <- pending do
      assert {:ok, %Result{}} =
               Portico.Test.call_tool(mcp, tool, %{},
                 request_state: token,
                 input_responses: %{"form" => %{"action" => "cancel"}}
               )

      assert_received {:handled, :cancel, _, _}
    end

    assert_received :verified

    Application.put_env(:portico, Server, elicitation_key: String.duplicate("new-key-", 4))

    for {tool, token} <- pending do
      assert {:error, :invalid_request_state} =
               Portico.Test.call_tool(mcp, tool, %{},
                 request_state: token,
                 input_responses: %{"form" => %{"action" => "cancel"}}
               )

      {:ok, _, fresh_token} = Portico.Test.call_tool(mcp, tool, %{})

      assert {:ok, %Result{}} =
               Portico.Test.call_tool(mcp, tool, %{},
                 request_state: fresh_token,
                 input_responses: %{"form" => %{"action" => "cancel"}}
               )

      assert_received {:handled, :cancel, _, _}
    end

    assert_received :verified
    refute_received :verified
    refute_received {:handled, _, _, _}
  end

  test "tampered state produces invalid params over the protocol", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})

    message = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "work",
        "arguments" => %{},
        "requestState" => token <> "x",
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => mcp.client_capabilities
        }
      }
    }

    assert {:reply, %{"error" => %{"code" => -32602}}} =
             Portico.Protocol.Dispatcher.dispatch(Server, message, mcp.assigns)

    refute_received :verified
  end

  test "a function verifier runs only on replies, restores state and sees fresh assigns", %{
    mcp: mcp
  } do
    assert {:ok, %Input{}, token} = Portico.Test.call_tool(mcp, "work", %{})
    refute_received :verified

    assert {:ok, %Result{}} =
             resume(mcp, token, %{"action" => "accept", "content" => %{"name" => "Ada"}},
               assigns: %{locale: "en"}
             )

    assert_received :verified

    assert_received {:handled, {:accept, %{"name" => "Ada"}}, "verified:application-state",
                     %{locale: "en"}}

    for action <- ["decline", "cancel"] do
      assert {:ok, %Result{}} = resume(mcp, token, %{"action" => action})
      assert_received :verified
      expected = if action == "decline", do: :decline, else: :cancel
      assert_received {:handled, ^expected, _, _}
    end
  end

  test "missing and schema-invalid answers reissue the form without invoking handler", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})
    assert {:ok, %Input{}, _} = Portico.Test.call_tool(mcp, "work", %{}, request_state: token)

    assert {:ok, %Input{}, _} =
             Portico.Test.call_tool(mcp, "work", %{},
               request_state: token,
               input_responses: %{"unknown" => %{}}
             )

    for content <- [%{}, %{"name" => ""}, %{"name" => 1}, %{"name" => ["Ada"]}] do
      assert {:ok, %Input{}, _} =
               resume(mcp, token, %{"action" => "accept", "content" => content})
    end

    refute_received {:handled, _, _, _}
  end

  test "tampering and use with changed arguments or another tool is rejected", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})
    assert {:error, :invalid_request_state} = resume(mcp, token <> "x", %{"action" => "cancel"})

    assert {:error, :invalid_request_state} =
             Portico.Test.call_tool(mcp, "other", %{}, request_state: token)

    assert {:error, :invalid_request_state} =
             Portico.Test.call_tool(mcp, "work", %{"changed" => true}, request_state: token)

    refute_received :verified
    refute_received {:handled, _, _, _}
  end

  test "verifier failures remain visible to helpers and prevent handling", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})

    for {mode, reason} <- [reject: :denied, bad: :invalid_verifier_return] do
      assert {:error, ^reason} =
               resume(mcp, token, %{"action" => "cancel"}, assigns: %{verifier_mode: mode})
    end

    assert_raise RuntimeError, "verifier failed", fn ->
      resume(mcp, token, %{"action" => "cancel"}, assigns: %{verifier_mode: :raise})
    end

    refute_received {:handled, _, _, _}
  end

  test "unsupported clients never receive forms or invoke reply handlers", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})

    for capabilities <- [%{}, %{"elicitation" => %{"url" => %{}}}] do
      context = %{mcp | client_capabilities: capabilities}
      assert {:error, :form_not_supported} = Portico.Test.call_tool(context, "work", %{})
      assert {:error, :form_not_supported} = resume(context, token, %{"action" => "cancel"})

      for extra <- [
            %{},
            %{"requestState" => token, "inputResponses" => %{"form" => %{"action" => "cancel"}}}
          ] do
        message = %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" =>
            Map.merge(
              %{
                "name" => "work",
                "arguments" => %{},
                "_meta" => %{
                  "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                  "io.modelcontextprotocol/clientCapabilities" => capabilities
                }
              },
              extra
            )
        }

        assert Portico.Protocol.Dispatcher.dispatch(Server, message, mcp.assigns) ==
                 {:reply, Portico.Protocol.Error.response(:form_not_supported, 9)}
      end
    end

    refute_received :verified

    assert {:ok, %Input{}, _} =
             Portico.Test.call_tool(
               %{mcp | client_capabilities: %{"elicitation" => %{}}},
               "work",
               %{}
             )

    assert {:error, :missing_input_callback} = Portico.Test.call_tool(mcp, "missing", %{})
  end

  test "malformed replies are rejected structurally", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "work", %{})

    for reply <- [
          nil,
          %{},
          %{"action" => "other"},
          %{"action" => "accept", "content" => []},
          %{"action" => "accept", "content" => %{"name" => [1]}},
          %{"action" => "accept", "content" => %{"name" => [["Ada"]]}},
          %{"action" => "accept", "content" => %{"name" => %{}}}
        ] do
      assert {:error, :invalid_params} = resume(mcp, token, reply)
    end

    for opts <- [
          [input_responses: %{}],
          [request_state: nil],
          [request_state: token, input_responses: []]
        ] do
      assert {:error, :invalid_params} = Portico.Test.call_tool(mcp, "work", %{}, opts)
    end

    refute_received :verified
  end

  test "expiry, missing configuration and malformed state fail closed", %{mcp: mcp} do
    {:ok, form, _} = Portico.Test.call_tool(mcp, "work", %{})
    request = %Request{server: Server, tool_name: "work", arguments: %{}}

    expired =
      Plug.Crypto.sign(
        String.duplicate("k", 32),
        "portico:elicitation:v1",
        %{version: 1, server: Server, tool: "work", arguments: %{}, form: form, state: "old"},
        signed_at: System.os_time(:second) - 600
      )

    assert {:error, :invalid_request_state} = Portico.Elicitation.verify(expired, request)
    assert {:error, :invalid_request_state} = Portico.Elicitation.verify(nil, request)

    assert {:error, :elicitation_key_missing} =
             Portico.Elicitation.verify("x", %{request | server: __MODULE__})

    assert {:error, :invalid_request_state} = Elicitation.encode(form, nil, request)
  end
end
