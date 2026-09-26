defmodule Portico.PromptTest do
  use ExUnit.Case, async: true
  alias Portico.{Prompt, Server, Test}
  alias Portico.Protocol.Dispatcher

  defmodule Review do
    use Prompt,
      description: "Review code",
      arguments: [code: [description: "Source", required: true], language: []]

    def get(arguments, request) do
      if observer = request.assigns[:observer], do: send(observer, {:called, arguments, request})

      case request.assigns[:mode] do
        :error ->
          {:error, :unavailable}

        :bad ->
          {:ok, "not a prompt"}

        :empty ->
          {:ok, %Prompt{}}

        :forged ->
          {:ok, %Prompt{messages: [%{role: "user", content: %{type: "text", text: <<255>>}}]}}

        :raise ->
          raise "application failure"

        _ ->
          Prompt.text("Review: " <> arguments["code"])
      end
    end
  end

  defmodule Empty do
    use Prompt
    def get(arguments, _), do: Prompt.text(inspect(arguments))
  end

  defmodule Catalog do
    use Portico.Server, name: "prompts", version: "1"
    prompt "review", Review
    prompt "empty", Empty
  end

  defmodule NoPrompts do
    use Portico.Server, name: "empty", version: "1"
  end

  test "text constructor and fresh callback context" do
    assert {:ok, %Prompt{messages: [%{role: "user", content: %{type: "text", text: ""}}]}} =
             Prompt.text("")

    assert Prompt.text(nil) == {:error, :invalid_text}
    assert Prompt.text(<<255>>) == {:error, :invalid_text}

    context = %Portico.Test.Context{server: Catalog, assigns: %{observer: self(), locale: "en"}}

    assert {:ok, %Prompt{messages: [%{content: %{text: "Review: 1 + 1"}}]}} =
             Test.get_prompt(context, "review", %{"code" => "1 + 1"}, assigns: %{locale: "de"})

    assert_received {:called, %{"code" => "1 + 1"},
                     %Portico.Request{
                       server: Catalog,
                       prompt_name: "review",
                       method: "prompts/get",
                       arguments: %{"code" => "1 + 1"},
                       assigns: %{locale: "de"},
                       tool_name: nil,
                       resource_uri: nil
                     }}

    assert context.assigns.locale == "en"
    assert {:ok, _} = Test.get_prompt(Catalog, "review", %{"code" => "", "language" => "en"})
    refute_received {:called, _, _}
  end

  test "sorted listing advertises prompt arguments and capability only when declared" do
    assert Enum.map(Server.prompts(Catalog), & &1.name) == ["empty", "review"]
    {:reply, listing} = Dispatcher.dispatch(Catalog, message("prompts/list"))

    assert listing["result"]["prompts"] == [
             %{"name" => "empty", "arguments" => []},
             %{
               "name" => "review",
               "description" => "Review code",
               "arguments" => [
                 %{"name" => "code", "description" => "Source", "required" => true},
                 %{"name" => "language", "required" => false}
               ]
             }
           ]

    assert listing["result"]["cacheScope"] == "private"
    assert listing["result"]["ttlMs"] == 0
    {:reply, discover} = Dispatcher.dispatch(Catalog, message("server/discover"))
    assert discover["result"]["capabilities"]["prompts"] == %{}
    {:reply, discover} = Dispatcher.dispatch(NoPrompts, message("server/discover"))
    refute Map.has_key?(discover["result"]["capabilities"], "prompts")
    {:reply, listing} = Dispatcher.dispatch(NoPrompts, message("prompts/list"))
    assert listing["result"]["prompts"] == []

    assert {:reply, %{"error" => %{"code" => -32602}}} =
             Dispatcher.dispatch(Catalog, message("prompts/list", %{"cursor" => "unsupported"}))
  end

  test "get emits one user text message and allows omitted arguments for argument-free prompts" do
    {:reply, reply} =
      Dispatcher.dispatch(
        Catalog,
        message("prompts/get", %{"name" => "review", "arguments" => %{"code" => "x"}})
      )

    assert reply["result"]["resultType"] == "complete"

    assert reply["result"]["messages"] == [
             %{"role" => "user", "content" => %{"type" => "text", "text" => "Review: x"}}
           ]

    {:reply, reply} = Dispatcher.dispatch(Catalog, message("prompts/get", %{"name" => "empty"}))
    assert hd(reply["result"]["messages"])["content"]["text"] == "%{}"
  end

  test "invalid names and arguments never invoke the callback" do
    for params <- [
          %{},
          %{"name" => ""},
          %{"name" => "missing"},
          %{"name" => "review"},
          %{"name" => "review", "arguments" => nil},
          %{"name" => "review", "arguments" => %{"code" => 1}},
          %{"name" => "review", "arguments" => %{code: "x"}},
          %{"name" => "review", "arguments" => %{"code" => <<255>>}},
          %{"name" => "review", "arguments" => %{"code" => "x", "extra" => "y"}},
          %{"name" => "empty", "requestState" => "unsupported"},
          %{"name" => "empty", "inputResponses" => %{}}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(Catalog, message("prompts/get", params), %{observer: self()})
    end

    assert Test.get_prompt(Catalog, "missing", %{}) == {:error, :unknown_prompt}
    assert Test.get_prompt(Catalog, "review", %{}) == {:error, :invalid_params}
    refute_received {:called, _, _}
  end

  test "callback errors and invalid results return tuples; HTTP sanitizes failures" do
    for {mode, reason} <- [
          error: :unavailable,
          bad: :invalid_callback_return,
          empty: :invalid_prompt,
          forged: :invalid_prompt
        ] do
      assert Test.get_prompt(Catalog, "review", %{"code" => "x"}, assigns: %{mode: mode}) ==
               {:error, reason}

      assert {:reply, %{"error" => %{"code" => -32603}}} =
               Dispatcher.dispatch(
                 Catalog,
                 message("prompts/get", %{"name" => "review", "arguments" => %{"code" => "x"}}),
                 %{mode: mode}
               )
    end

    assert_raise RuntimeError, "application failure", fn ->
      Test.get_prompt(Catalog, "review", %{"code" => "x"}, assigns: %{mode: :raise})
    end

    assert {:reply, %{"error" => %{"code" => -32603}}} =
             Dispatcher.dispatch(
               Catalog,
               message("prompts/get", %{"name" => "review", "arguments" => %{"code" => "x"}}),
               %{mode: :raise}
             )
  end

  test "helper validates options, context and metadata" do
    assert Test.get_prompt(nil, "empty", %{}) == {:error, :invalid_server}
    assert Test.get_prompt(%{}, "empty", %{}) == {:error, :invalid_target}
    assert Test.get_prompt(Catalog, "empty", %{}, unknown: 1) == {:error, :invalid_options}

    assert Test.get_prompt(Catalog, "empty", %{}, assigns: %{"bad" => 1}) ==
             {:error, :invalid_assigns}

    assert Test.get_prompt(%Portico.Test.Context{server: Catalog, assigns: nil}, "empty", %{}) ==
             {:error, :invalid_assigns}

    assert {:error, {:unsupported_protocol_version, "old", _}} =
             Test.get_prompt(
               %Portico.Test.Context{server: Catalog, protocol_version: "old"},
               "empty",
               %{}
             )

    assert {:error, :method_not_found} =
             Dispatcher.get_prompt_request(Catalog, message("tools/list"), %{})

    assert {:error, :invalid_request} =
             Dispatcher.get_prompt_request(Catalog, Map.delete(message("prompts/get"), "id"), %{})
  end

  test "HTTP validates Mcp-Name and serves prompt results" do
    for {header, status, code} <- [{"review", 200, nil}, {"wrong", 400, -32020}] do
      conn =
        Plug.Test.conn(
          :post,
          "/mcp",
          JSON.encode!(
            message("prompts/get", %{"name" => "review", "arguments" => %{"code" => "x"}})
          )
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
        |> Plug.Conn.put_req_header("mcp-method", "prompts/get")
        |> Plug.Conn.put_req_header("mcp-name", header)
        |> Portico.Plug.call(Portico.Plug.init(server: Catalog))

      assert conn.status == status
      body = JSON.decode!(conn.resp_body)

      if code,
        do: assert(body["error"]["code"] == code),
        else: assert(length(body["result"]["messages"]) == 1)
    end
  end

  defp message(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }
  end
end
