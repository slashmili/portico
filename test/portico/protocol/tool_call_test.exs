defmodule Portico.Protocol.ToolCallTest do
  use ExUnit.Case, async: true
  alias Portico.Protocol.Dispatcher

  defmodule Add do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(%{"a" => a, "b" => b}, _request) do
      {:ok, Portico.Result.text("#{a + b}")}
    end
  end

  defmodule Context do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(arguments, request) do
      text =
        JSON.encode!(%{
          "id" => request.id,
          "method" => request.method,
          "protocol_version" => request.protocol_version,
          "client_info" => request.client_info,
          "capabilities" => request.client_capabilities,
          "assigns" => request.assigns,
          "arguments" => arguments
        })

      {:ok, Portico.Result.text(text)}
    end
  end

  defmodule Broken do
    use Portico.Tool, input_schema: %{}
    @impl true
    def call(%{"raise" => true}, _), do: raise("secret application detail")
    def call(%{"shape" => true}, _), do: {:reply, "secret", %{}}

    def call(%{"flag" => flag}, _request) do
      {:ok, Map.put(Portico.Result.text("private"), :is_error, flag)}
    end

    def call(%{"content" => content}, _request) do
      {:ok, %Portico.Result{content: content}}
    end
  end

  defmodule Server do
    use Portico.Server, name: "call-test", version: "1"
    tool "add", Add
    tool "context", Context
    tool "broken", Broken
  end

  defp request(name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  test "calls a declared tool and encodes a completed text result" do
    assert Dispatcher.dispatch(Server, request("add", %{"a" => 2, "b" => 3})) ==
             {:reply,
              %{
                "jsonrpc" => "2.0",
                "id" => 7,
                "result" => %{
                  "resultType" => "complete",
                  "isError" => false,
                  "content" => [%{"type" => "text", "text" => "5"}],
                  "_meta" => %{
                    "io.modelcontextprotocol/serverInfo" => %{
                      "name" => "call-test",
                      "version" => "1"
                    }
                  }
                }
              }}
  end

  test "omitted arguments default to an empty map and context is fresh each time" do
    message = request("context", %{}) |> Map.update!("params", &Map.delete(&1, "arguments"))

    for _ <- 1..2 do
      assert {:reply, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Dispatcher.dispatch(Server, message)

      assert JSON.decode!(text) == %{
               "id" => 7,
               "method" => "tools/call",
               "protocol_version" => "2026-07-28",
               "client_info" => nil,
               "capabilities" => %{},
               "assigns" => %{},
               "arguments" => %{}
             }
    end
  end

  test "passes client information and capabilities without treating them as assigns" do
    info = %{"name" => "client", "version" => "dev"}
    caps = %{"elicitation" => %{"form" => %{}}}

    message =
      request("context", %{"value" => "42"})
      |> put_in(["params", "_meta", "io.modelcontextprotocol/clientInfo"], info)
      |> put_in(["params", "_meta", "io.modelcontextprotocol/clientCapabilities"], caps)

    assert {:reply, %{"result" => %{"content" => [%{"text" => text}]}}} =
             Dispatcher.dispatch(Server, message)

    data = JSON.decode!(text)
    assert data["client_info"] == info
    assert data["capabilities"] == caps
    assert data["assigns"] == %{}
    assert data["arguments"] == %{"value" => "42"}
  end

  test "rejects unknown tools and malformed call parameters" do
    messages = [
      request("missing", %{}),
      request(nil, %{}),
      request(42, %{}),
      request(<<255>>, %{}),
      update_in(request("add", %{}), ["params"], &Map.delete(&1, "name"))
    ]

    messages =
      messages ++ Enum.map([nil, [], "args", %Portico.Request{}, %{a: 2}], &request("add", &1))

    for message <- messages do
      assert {:reply, %{"error" => %{"code" => -32602}, "id" => 7}} =
               Dispatcher.dispatch(Server, message)
    end
  end

  test "application exceptions and malformed results produce a generic internal error" do
    arguments =
      [%{"raise" => true}, %{"shape" => true}] ++
        Enum.map(
          [
            nil,
            [%{type: "text", text: <<255>>}],
            [%{type: "text", text: 42}],
            [%{type: "image", data: "secret"}],
            [%{type: "text", text: "ok", extra: "secret"}]
          ],
          &%{"content" => &1}
        )

    for args <- arguments do
      assert Dispatcher.dispatch(Server, request("broken", args)) ==
               {:reply,
                %{
                  "jsonrpc" => "2.0",
                  "id" => 7,
                  "error" => %{"code" => -32603, "message" => "Internal error"}
                }}
    end
  end

  test "rejects malformed error flags instead of emitting non-boolean isError" do
    for flag <- [nil, "true", 1, %{}] do
      assert {:reply, %{"error" => %{"code" => -32603}}} =
               Dispatcher.dispatch(Server, request("broken", %{"flag" => flag}))
    end
  end

  test "encodes empty and multiple text items in order" do
    for content <- [[], [%{type: "text", text: "first"}, %{type: "text", text: "Grüße"}]] do
      assert {:reply, response} =
               Dispatcher.dispatch(Server, request("broken", %{"content" => content}))

      assert response["result"]["content"] ==
               Enum.map(content, &%{"type" => "text", "text" => &1.text})

      assert JSON.decode!(JSON.encode!(response)) == response
    end
  end

  test "validation and notification suppression happen before execution" do
    message = request("broken", %{"raise" => true})
    assert Dispatcher.dispatch(Server, Map.delete(message, "id")) == :no_response

    assert {:reply, %{"error" => %{"code" => -32602}}} =
             Dispatcher.dispatch(Server, put_in(message, ["params", "_meta"], %{}))

    assert {:reply, %{"error" => %{"code" => -32022}}} =
             Dispatcher.dispatch(
               Server,
               put_in(
                 message,
                 ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
                 "old"
               )
             )
  end
end
