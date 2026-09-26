defmodule Portico.SamplingTest do
  use ExUnit.Case, async: true
  alias Portico.{Input, Request, Result}
  alias Portico.Protocol.{Dispatcher, Elicitation, Sampling}
  alias Portico.Test.Context

  defmodule Tool do
    use Portico.Tool, input_schema: %{}, elicitation_verifier: &__MODULE__.verify/2
    def verify(_, _), do: {:error, :elicitation_verifier_must_not_run}
    @impl true
    def call(%{"stream" => true}, _), do: {:noreply, nil, :stream}

    def call(_, _) do
      {:ok, input} = Input.sample("Summarize this", max_tokens: 200)
      {:ok, input, "sampling:v1"}
    end

    @impl true
    def handle_stream(_, _), do: call(%{}, nil)
    @impl true
    def handle_input({:sample, answer}, state, request) do
      send(request.assigns.observer, {:answer, answer, state, request.assigns})
      {:ok, result} = Result.text(answer.text)
      {:ok, result}
    end
  end

  defmodule Server do
    use Portico.Server, name: "sampling", version: "1"
    tool "sample", Tool
    tool "other", Tool
  end

  setup do
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("k", 32))
    on_exit(fn -> Application.delete_env(:portico, Server) end)

    %{
      mcp: %Context{
        server: Server,
        client_capabilities: %{"sampling" => %{}},
        assigns: %{observer: self()}
      }
    }
  end

  defp answer do
    %{
      "role" => "assistant",
      "model" => "test",
      "stopReason" => "endTurn",
      "content" => %{"type" => "text", "text" => "Summary"}
    }
  end

  defp message(arguments, extra \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" =>
        Map.merge(
          %{
            "name" => "sample",
            "arguments" => arguments,
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}}
            }
          },
          extra
        )
    }
  end

  defp resume(mcp, token, response, options \\ []) do
    Portico.Test.call_tool(
      mcp,
      "sample",
      %{},
      Keyword.merge(
        [
          request_state: token,
          input_responses: %{"sample" => response}
        ],
        options
      )
    )
  end

  test "sample constructor validates runtime arguments" do
    assert {:ok, %Input{mode: :sample, message: "Hello", max_tokens: 10}} =
             Input.sample("Hello", max_tokens: 10)

    for message <- [nil, 42, <<255>>],
        do: assert({:error, :invalid_message} = Input.sample(message, max_tokens: 10))

    for options <- [nil, %{}, [], [temperature: 1], [max_tokens: 1, max_tokens: 2]],
        do: assert({:error, :invalid_options} = Input.sample("Hello", options))

    for value <- [nil, 0, -1, 1.5, "10"],
        do: assert({:error, :invalid_max_tokens} = Input.sample("Hello", max_tokens: value))
  end

  test "encodes one user text request with required token limit" do
    assert {:reply, %{"result" => fields}} = Dispatcher.dispatch(Server, message(%{}))
    assert fields["resultType"] == "input_required"
    assert %{"sample" => request} = fields["inputRequests"]

    assert request == %{
             "method" => "sampling/createMessage",
             "params" => %{
               "messages" => [
                 %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize this"}}
               ],
               "maxTokens" => 200,
               "includeContext" => "none"
             }
           }

    assert is_binary(fields["requestState"])
  end

  test "retries restore signed state and fresh assigns without invoking the elicitation verifier",
       %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "sample", %{})

    for content <- [answer()["content"], [answer()["content"]]] do
      assert {:ok, %Result{content: [%{text: "Summary"}]}} =
               resume(mcp, token, %{answer() | "content" => content}, assigns: %{locale: "de"})

      assert_received {:answer, %{text: "Summary", model: "test", stop_reason: "endTurn"},
                       "sampling:v1", %{locale: "de"}}
    end

    assert {:ok, _} = resume(mcp, token, Map.delete(answer(), "stopReason"))
    assert_received {:answer, actual, _, _}
    refute Map.has_key?(actual, :stop_reason)
  end

  test "requires sampling on initial requests and retries", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "sample", %{})
    missing = %{mcp | client_capabilities: %{}}
    assert {:error, :sampling_not_supported} = Portico.Test.call_tool(missing, "sample", %{})
    assert {:error, :sampling_not_supported} = resume(missing, token, answer())

    request =
      put_in(message(%{}), ["params", "_meta", "io.modelcontextprotocol/clientCapabilities"], %{})

    assert {:reply,
            %{
              "error" => %{
                "code" => -32021,
                "data" => %{"requiredCapabilities" => %{"sampling" => %{}}}
              }
            }} = Dispatcher.dispatch(Server, request)
  end

  test "malformed or unsupported answers are rejected without callback", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "sample", %{})

    for response <- [
          nil,
          %{},
          Map.delete(answer(), "model"),
          %{answer() | "model" => nil},
          %{answer() | "role" => "system"},
          %{answer() | "stopReason" => nil},
          %{answer() | "content" => []},
          %{answer() | "content" => [answer()["content"], answer()["content"]]},
          %{answer() | "content" => %{"type" => "image", "data" => ""}},
          %{answer() | "content" => %{"type" => "text", "text" => 1}}
        ] do
      assert {:error, :invalid_params} = resume(mcp, token, response)
    end

    assert {:error, :invalid_params} = Sampling.decode(%{answer() | "model" => <<255>>})
    refute_received {:answer, _, _, _}

    assert {:reply, %{"error" => %{"code" => -32602}}} =
             Dispatcher.dispatch(
               Server,
               message(%{}, %{"requestState" => token, "inputResponses" => %{"sample" => %{}}})
             )
  end

  test "missing answers reissue sampling and wrong input types are rejected", %{mcp: mcp} do
    {:ok, input, token} = Portico.Test.call_tool(mcp, "sample", %{})
    assert {:ok, ^input, _} = Portico.Test.call_tool(mcp, "sample", %{}, request_state: token)

    for responses <- [
          %{"form" => %{"action" => "cancel"}},
          %{"url" => %{"action" => "accept"}},
          %{"sample" => answer(), "form" => %{"action" => "cancel"}}
        ] do
      assert {:error, :invalid_params} =
               Portico.Test.call_tool(mcp, "sample", %{},
                 request_state: token,
                 input_responses: responses
               )
    end

    assert {:input_error, :invalid_params} =
             Elicitation.match_answer({:sample, %{}}, %Input{mode: :form})

    refute_received {:answer, _, _, _}
  end

  test "tampering, changed arguments/tool/key and expiration reject continuation", %{mcp: mcp} do
    {:ok, _, token} = Portico.Test.call_tool(mcp, "sample", %{})
    assert {:error, :invalid_request_state} = resume(mcp, token <> "x", answer())

    for {tool, args} <- [{"other", %{}}, {"sample", %{"changed" => true}}] do
      assert {:error, :invalid_request_state} =
               Portico.Test.call_tool(mcp, tool, args,
                 request_state: token,
                 input_responses: %{"sample" => answer()}
               )
    end

    request = %Request{server: Server, tool_name: "sample", arguments: %{}}
    {:ok, payload} = Portico.Elicitation.open(token, request)

    expired =
      Plug.Crypto.sign(String.duplicate("k", 32), "portico:elicitation:v1", payload,
        signed_at: System.os_time(:second) - 600
      )

    assert {:error, :invalid_request_state} = resume(mcp, expired, answer())
    Application.put_env(:portico, Server, elicitation_key: String.duplicate("n", 32))
    assert {:error, :invalid_request_state} = resume(mcp, token, answer())
    refute_received {:answer, _, _, _}
  end

  test "streaming callbacks can request sampling and preserve capability failures", %{mcp: mcp} do
    assert {:ok, %Input{mode: :sample}, token} =
             Portico.Test.call_tool(mcp, "sample", %{"stream" => true})

    assert {:ok, %Result{}} =
             Portico.Test.call_tool(mcp, "sample", %{"stream" => true},
               request_state: token,
               input_responses: %{"sample" => answer()}
             )

    assert {:error, :sampling_not_supported} =
             Portico.Test.call_tool(%{mcp | client_capabilities: %{}}, "sample", %{
               "stream" => true
             })

    {:stream, execution} = Dispatcher.dispatch(Server, message(%{"stream" => true}))
    execution = put_in(execution, [:request, Access.key(:client_capabilities)], %{})
    conn = Portico.Transport.SSE.call(Plug.Test.conn(:post, "/mcp"), execution, 1000)
    assert conn.resp_body =~ "-32021"
  end

  test "invalid input structs and non-tool sampling are rejected" do
    request = %Request{
      server: Server,
      method: "tools/call",
      client_capabilities: %{"sampling" => %{}}
    }

    assert {:error, :invalid_max_tokens} =
             Elicitation.encode(
               %Input{mode: :sample, message: "x", max_tokens: 0},
               "state",
               request
             )

    assert {:error, :invalid_input} =
             Elicitation.encode(
               %Input{mode: :sample, message: "x", schema: %{}, max_tokens: 1},
               "state",
               request
             )

    assert {:error, :invalid_input} =
             Elicitation.encode(%Input{mode: :sample}, "state", %{
               request
               | method: "resources/read"
             })
  end
end
