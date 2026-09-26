defmodule Portico.CompletionTest do
  use ExUnit.Case, async: true
  alias Portico.Test
  alias Portico.Protocol.Dispatcher

  defmodule Prompt do
    use Portico.Prompt, arguments: [language: [required: true], framework: [required: true]]
    def get(_, _), do: raise("completion must not run get")

    def complete(name, prefix, request) do
      if pid = request.assigns[:observer], do: send(pid, {:completed, name, prefix, request})

      case request.assigns[:mode] do
        :error -> {:error, :unavailable}
        :bad -> :bad
        :raise -> raise "completion failed"
        _ -> {:ok, Map.get(request.assigns, :values, [request.arguments["language"] || prefix])}
      end
    end
  end

  defmodule Resource do
    use Portico.Resource, name: "resource"
    def read(_), do: raise("completion must not run read")
    defdelegate complete(name, prefix, request), to: Prompt
  end

  defmodule Plain do
    use Portico.Prompt, arguments: [name: []]
    def get(_, _), do: Portico.Prompt.text("")
  end

  defmodule Server do
    use Portico.Server, name: "completion", version: "1"
    prompt "work", Prompt
    prompt "plain", Plain
    resource_template "company://docs/{language}/{framework}", Resource
  end

  defmodule NoCompletion do
    use Portico.Server, name: "plain", version: "1"
    prompt "plain", Plain
  end

  defmodule ResourceOnly do
    use Portico.Server, name: "resource", version: "1"
    resource_template "company://docs/{language}", Resource
  end

  test "callbacks receive partial context and fresh assigns for prompt and exact template references" do
    context = %Portico.Test.Context{server: Server, assigns: %{observer: self(), locale: "en"}}

    for ref <- [{:prompt, "work"}, {:resource, "company://docs/{language}/{framework}"}] do
      assert {:ok, %{values: ["elixir"], total: 1, has_more: false}} =
               Test.complete(context, ref, "framework", "ph",
                 arguments: %{"language" => "elixir"},
                 assigns: %{locale: "de"}
               )

      assert_received {:completed, "framework", "ph", request}
      assert request.arguments == %{"language" => "elixir"}
      assert request.assigns.locale == "de"
      assert request.method == "completion/complete"
      assert request.server == Server

      case ref do
        {:prompt, name} -> assert request.prompt_name == name
        {:resource, uri} -> assert request.resource_route == {Resource, uri}
      end
    end

    assert context.assigns.locale == "en"
    assert {:ok, %{values: [""]}} = Test.complete(Server, {:prompt, "work"}, "language", "")

    assert {:ok, %{values: [], total: 0, has_more: false}} =
             Test.complete(Server, {:prompt, "plain"}, "name", "")
  end

  test "completion capability is advertised only for usable callbacks" do
    for server <- [Server, ResourceOnly] do
      {:reply, reply} = Dispatcher.dispatch(server, message("server/discover", %{}))
      assert reply["result"]["capabilities"]["completions"] == %{}
    end

    {:reply, reply} = Dispatcher.dispatch(NoCompletion, message("server/discover", %{}))
    refute Map.has_key?(reply["result"]["capabilities"], "completions")

    assert Test.complete(NoCompletion, {:prompt, "plain"}, "name", "") ==
             {:error, :method_not_found}

    assert {:reply, %{"error" => %{"code" => -32601}}} =
             Dispatcher.dispatch(NoCompletion, message("completion/complete", params()))
  end

  test "results preserve order and derive total and hasMore without returning more than 100" do
    for size <- [0, 100, 101] do
      values = for n <- Enum.take(1..101, size), do: Integer.to_string(n)

      assert {:ok, result} =
               Test.complete(Server, {:prompt, "work"}, "language", "",
                 assigns: %{values: values}
               )

      assert result == %{values: Enum.take(values, 100), total: size, has_more: size > 100}

      {:reply, reply} =
        Dispatcher.dispatch(Server, message("completion/complete", params()), %{values: values})

      assert reply["result"]["completion"] == %{
               "values" => Enum.take(values, 100),
               "total" => size,
               "hasMore" => size > 100
             }

      assert reply["result"]["resultType"] == "complete"
    end
  end

  test "malformed refs, argument names, values and context never invoke callbacks" do
    for extra <- [
          %{"ref" => nil},
          %{"ref" => %{"type" => "ref/tool", "name" => "work"}},
          %{"ref" => %{"type" => "ref/prompt", "name" => "missing"}},
          %{"ref" => %{"type" => "ref/resource", "uri" => "company://docs/elixir/phoenix"}},
          %{"argument" => nil},
          %{"argument" => %{}},
          %{"argument" => %{"name" => "missing", "value" => ""}},
          %{"argument" => %{"name" => "language", "value" => 1}},
          %{"argument" => %{"name" => "language", "value" => <<255>>}},
          %{"context" => nil},
          %{"context" => []},
          %{"context" => %{"arguments" => nil}},
          %{"context" => %{"arguments" => %{"language" => 1}}},
          %{"context" => %{"arguments" => %{"unknown" => "x"}}},
          %{"context" => %{"arguments" => %{language: "x"}}}
        ] do
      assert {:reply, %{"error" => %{"code" => -32602}}} =
               Dispatcher.dispatch(
                 Server,
                 message("completion/complete", Map.merge(params(), extra)),
                 %{observer: self()}
               )
    end

    refute_received {:completed, _, _, _}
  end

  test "callback failures remain tuples and HTTP sanitizes errors and exceptions" do
    for value <- [nil, "bad", [1], [<<255>>], ["valid" | :invalid]] do
      assert Test.complete(Server, {:prompt, "work"}, "language", "", assigns: %{values: value}) ==
               {:error, :invalid_completion}
    end

    for {mode, reason} <- [error: :unavailable, bad: :invalid_callback_return] do
      assert Test.complete(Server, {:prompt, "work"}, "language", "", assigns: %{mode: mode}) ==
               {:error, reason}
    end

    for assigns <- [%{mode: :error}, %{mode: :bad}, %{mode: :raise}, %{values: [1]}] do
      assert {:reply, %{"error" => %{"code" => -32603}}} =
               Dispatcher.dispatch(Server, message("completion/complete", params()), assigns)
    end

    assert_raise RuntimeError, "completion failed", fn ->
      Test.complete(Server, {:prompt, "work"}, "language", "", assigns: %{mode: :raise})
    end
  end

  test "helper validates configuration and uses metadata validation" do
    assert Test.complete(%{}, {:prompt, "work"}, "language", "") == {:error, :invalid_target}
    assert Test.complete(nil, {:prompt, "work"}, "language", "") == {:error, :invalid_server}
    assert Test.complete(Server, :bad, "language", "") == {:error, :invalid_params}

    assert Test.complete(Server, {:prompt, "work"}, "language", "", unknown: 1) ==
             {:error, :invalid_options}

    assert Test.complete(Server, {:prompt, "work"}, "language", "", assigns: %{"bad" => 1}) ==
             {:error, :invalid_assigns}

    context = %Portico.Test.Context{server: Server, protocol_version: "old"}

    assert {:error, {:unsupported_protocol_version, "old", _}} =
             Test.complete(context, {:prompt, "work"}, "language", "")

    assert {:error, :method_not_found} =
             Dispatcher.complete_request(Server, message("prompts/list", %{}), %{})

    assert {:error, :invalid_request} =
             Dispatcher.complete_request(
               Server,
               Map.delete(message("completion/complete", params()), "id"),
               %{}
             )
  end

  defp params do
    %{
      "ref" => %{"type" => "ref/prompt", "name" => "work"},
      "argument" => %{"name" => "language", "value" => "el"}
    }
  end

  defp message(method, params) do
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
