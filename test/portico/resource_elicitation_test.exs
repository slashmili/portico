defmodule Portico.ResourceElicitationTest do
  use ExUnit.Case, async: true
  alias Portico.{Input, Resource, Test}
  alias Portico.Protocol.Dispatcher

  defmodule Form do
    use Resource, name: "form", mime_type: "text/plain"

    def read(request) do
      send(request.assigns.observer, {:read, request})

      {:ok, form} =
        Input.form("Language?",
          schema: %{
            type: "object",
            properties: %{language: %{type: "string", enum: ["en", "de"]}},
            required: ["language"]
          }
        )

      {:ok, form, "state"}
    end

    def handle_input(answer, state, request) do
      send(request.assigns.observer, {:handled, answer, state, request})

      case request.assigns[:mode] do
        :again ->
          read(request)

        :list ->
          {:ok, item} = Resource.text("item", uri: "company://child")
          {:ok, [item]}

        :missing ->
          {:error, :resource_not_found}

        :bad ->
          :bad

        :raise ->
          raise "callback failed"

        _ ->
          Resource.text("done")
      end
    end
  end

  defmodule Custom do
    use Resource, name: "custom", elicitation_verifier: &__MODULE__.verify/2
    defdelegate read(request), to: Form
    defdelegate handle_input(answer, state, request), to: Form

    def verify(token, request) do
      send(request.assigns.observer, :verified)

      case request.assigns[:verify] do
        :deny ->
          {:error, :denied}

        :bad ->
          :bad

        _ ->
          with {:ok, state} <- Portico.Elicitation.verify(token, request),
               do: {:ok, "custom:" <> state}
      end
    end
  end

  defmodule Missing do
    use Resource, name: "missing"
    defdelegate read(request), to: Form
  end

  defmodule Url do
    use Resource, name: "url", elicitation_verifier: &Custom.verify/2
    defdelegate handle_input(answer, state, request), to: Form

    def read(_) do
      {:ok, input} = Input.url("Open", url: "https://example.com")
      {:ok, input, "state"}
    end
  end

  defmodule Tool do
    use Portico.Tool, input_schema: %{}
    def call(_, request), do: Form.read(request)
    def handle_input(_, _, _), do: Portico.Result.text("tool")
  end

  defmodule Server do
    use Portico.Server, name: "forms", version: "1"
    resource "company://form", Form
    resource "company://alias", Form
    resource "company://custom", Custom
    resource "company://missing", Missing
    resource "company://url", Url
    resource_template "company://form/{name}", Form
    resource_template "company://url/{name}", Url
    tool "form", Tool
  end

  defmodule OtherServer do
    use Portico.Server, name: "other", version: "1"
    resource "company://form", Form
  end

  setup do
    for server <- [Server, OtherServer] do
      Application.put_env(:portico, server, elicitation_key: String.duplicate("k", 32))
      on_exit(fn -> Application.delete_env(:portico, server) end)
    end

    %{
      mcp: %Portico.Test.Context{
        server: Server,
        assigns: %{observer: self()},
        client_capabilities: %{"elicitation" => %{"form" => %{}}}
      }
    }
  end

  defp resume(mcp, uri, token, answer, options \\ []) do
    Test.read_resource(
      mcp,
      uri,
      Keyword.merge(
        [request_state: token, input_responses: %{"form" => answer}],
        options
      )
    )
  end

  test "static and template reads resume with fresh context and accept, decline, cancel", %{
    mcp: mcp
  } do
    for uri <- ["company://form", "company://form/de"],
        answer <- [
          %{"action" => "accept", "content" => %{"language" => "de"}},
          %{"action" => "decline"},
          %{"action" => "cancel"}
        ] do
      assert {:ok, %Input{}, token} = Test.read_resource(mcp, uri)

      assert {:ok, %Resource{uri: ^uri, text: "done"}} =
               resume(mcp, uri, token, answer, assigns: %{fresh: true})

      assert_received {:handled, _, "state",
                       %Portico.Request{resource_uri: ^uri, assigns: %{fresh: true}}}
    end
  end

  test "missing or invalid answers reissue the form; handlers may ask again or return lists", %{
    mcp: mcp
  } do
    {:ok, form, token} = Test.read_resource(mcp, "company://form")
    assert {:ok, ^form, _} = Test.read_resource(mcp, "company://form", request_state: token)

    for content <- [%{}, %{"language" => "xx"}, %{"language" => 1}] do
      assert {:ok, ^form, _} =
               resume(mcp, "company://form", token, %{"action" => "accept", "content" => content})
    end

    refute_received {:handled, _, _, _}

    assert {:ok, ^form, _} =
             resume(mcp, "company://form", token, %{"action" => "cancel"},
               assigns: %{mode: :again}
             )

    assert {:ok, [%Resource{uri: "company://child"}]} =
             resume(mcp, "company://form", token, %{"action" => "cancel"},
               assigns: %{mode: :list}
             )
  end

  test "tokens are bound to server, route, module and exact URI, separate from tools", %{mcp: mcp} do
    {:ok, _, token} = Test.read_resource(mcp, "company://form")
    assert_received {:read, request}

    for altered <- [
          %{request | resource_route: {Custom, "company://form"}},
          %{request | resource_route: {Form, "company://{name}"}},
          %{request | resource_uri: "company://alias"}
        ] do
      assert {:error, :invalid_request_state} = Portico.Elicitation.verify(token, altered)
    end

    for uri <- ["company://alias", "company://form/de"] do
      assert {:error, :invalid_request_state} = Test.read_resource(mcp, uri, request_state: token)
    end

    assert {:error, :invalid_request_state} =
             Test.read_resource(%{mcp | server: OtherServer}, "company://form",
               request_state: token
             )

    assert {:error, :invalid_request_state} =
             Test.call_tool(mcp, "form", %{}, request_state: token)

    {:ok, _, tool_token} = Test.call_tool(mcp, "form", %{})

    assert {:error, :invalid_request_state} =
             Test.read_resource(mcp, "company://form", request_state: tool_token)

    {:ok, _, template_token} = Test.read_resource(mcp, "company://form/a")

    assert {:error, :invalid_request_state} =
             Test.read_resource(mcp, "company://form/b", request_state: template_token)

    refute_received {:handled, _, _, _}
  end

  test "tampered, expired and old-key tokens fail before custom verification", %{mcp: mcp} do
    {:ok, form, token} = Test.read_resource(mcp, "company://custom")
    assert_received {:read, request}
    refute_received :verified

    expired =
      Plug.Crypto.sign(
        String.duplicate("k", 32),
        "portico:elicitation:v1",
        %{
          version: 1,
          server: Server,
          tool: nil,
          arguments: nil,
          resource_route: request.resource_route,
          resource_uri: request.resource_uri,
          form: form,
          state: "state"
        },
        signed_at: System.os_time(:second) - 600
      )

    for invalid <- [token <> "x", expired] do
      assert {:error, :invalid_request_state} =
               Test.read_resource(mcp, "company://custom", request_state: invalid)
    end

    Application.put_env(:portico, Server, elicitation_key: String.duplicate("x", 32))

    assert {:error, :invalid_request_state} =
             Test.read_resource(mcp, "company://custom", request_state: token)

    refute_received :verified
    refute_received {:handled, _, _, _}
  end

  test "custom verification receives fresh assigns and controls handler state", %{mcp: mcp} do
    refute Map.has_key?(Custom.__portico_resource__(), :elicitation_verifier)
    {:ok, _, token} = Test.read_resource(mcp, "company://custom")

    assert {:ok, %Resource{}} =
             resume(mcp, "company://custom", token, %{"action" => "cancel"},
               assigns: %{fresh: true}
             )

    assert_received :verified
    assert_received {:handled, :cancel, "custom:state", %{assigns: %{fresh: true}}}

    for {mode, reason} <- [deny: :denied, bad: :invalid_verifier_return] do
      assert {:error, ^reason} =
               resume(mcp, "company://custom", token, %{"action" => "cancel"},
                 assigns: %{verify: mode}
               )
    end

    refute_received {:handled, _, _, _}
  end

  test "wire input-required shape, invalid retries, capability errors and callback errors", %{
    mcp: mcp
  } do
    {:reply, pending} = Dispatcher.dispatch(Server, message(mcp, %{}), mcp.assigns)
    result = pending["result"]
    assert result["resultType"] == "input_required"
    assert result["inputRequests"]["form"]["method"] == "elicitation/create"
    refute Map.has_key?(result, "contents")
    refute Map.has_key?(result, "ttlMs")
    token = result["requestState"]
    reply = %{"requestState" => token, "inputResponses" => %{"form" => %{"action" => "cancel"}}}

    for {extra, assigns, code} <- [
          {Map.put(reply, "requestState", token <> "x"), mcp.assigns, -32602},
          {%{"inputResponses" => %{}}, mcp.assigns, -32602},
          {reply, Map.put(mcp.assigns, :mode, :missing), -32602},
          {reply, Map.put(mcp.assigns, :mode, :bad), -32603},
          {reply, Map.put(mcp.assigns, :mode, :raise), -32603}
        ] do
      assert {:reply, %{"error" => %{"code" => ^code}}} =
               Dispatcher.dispatch(Server, message(mcp, extra), assigns)
    end

    unsupported = %{mcp | client_capabilities: %{}}

    for extra <- [%{}, reply] do
      assert {:reply, %{"error" => %{"code" => -32021}}} =
               Dispatcher.dispatch(Server, message(unsupported, extra), mcp.assigns)
    end

    assert {:error, :form_not_supported} = Test.read_resource(unsupported, "company://form")

    assert {:error, :form_not_supported} =
             Test.read_resource(unsupported, "company://form", request_state: token)

    assert_raise RuntimeError, "callback failed", fn ->
      resume(mcp, "company://form", token, %{"action" => "cancel"}, assigns: %{mode: :raise})
    end

    assert {:error, :missing_input_callback} = Test.read_resource(mcp, "company://missing")
    assert {:error, :url_not_supported} = Test.read_resource(mcp, "company://url")

    assert {:error, :invalid_params} =
             Test.read_resource(mcp, "company://form", request_state: nil)

    assert {:error, :invalid_params} =
             Test.read_resource(mcp, "company://form",
               request_state: token,
               input_responses: %{"url" => %{"action" => "cancel"}}
             )

    Application.delete_env(:portico, Server)
    assert {:error, :elicitation_key_missing} = Test.read_resource(mcp, "company://form")
  end

  test "URL inputs support static and template reads, re-asking and all actions", %{mcp: mcp} do
    mcp = %{mcp | client_capabilities: %{"elicitation" => %{"url" => %{}}}}

    for uri <- ["company://url", "company://url/a"] do
      {:ok, input, token} = Test.read_resource(mcp, uri)
      assert input.mode == :url
      assert input.url == "https://example.com"
      assert {:ok, ^input, _} = Test.read_resource(mcp, uri, request_state: token)

      for action <- ["accept", "decline", "cancel"] do
        assert {:ok, %Resource{text: "done", uri: ^uri}} =
                 Test.read_resource(mcp, uri,
                   request_state: token,
                   input_responses: %{"url" => %{"action" => action}}
                 )

        assert_received {:handled, _, "custom:state", %Portico.Request{resource_uri: ^uri}}
      end

      assert {:error, :invalid_request_state} =
               Test.read_resource(mcp, uri, request_state: token <> "x")

      assert {:error, :invalid_request_state} =
               Test.read_resource(mcp, "company://url/other", request_state: token)

      for responses <- [
            %{"form" => %{"action" => "cancel"}},
            %{"url" => %{"action" => "accept", "content" => %{}}}
          ] do
        assert {:error, :invalid_params} =
                 Test.read_resource(mcp, uri, request_state: token, input_responses: responses)
      end
    end
  end

  test "URL resource capability errors use the URL requirement on initial and resumed reads", %{
    mcp: mcp
  } do
    supported = %{mcp | client_capabilities: %{"elicitation" => %{"url" => %{}}}}
    {:ok, _, token} = Test.read_resource(supported, "company://url")

    {:reply, pending} =
      Dispatcher.dispatch(Server, message(supported, %{"uri" => "company://url"}), mcp.assigns)

    assert pending["result"]["inputRequests"]["url"]["params"] ==
             %{"mode" => "url", "message" => "Open", "url" => "https://example.com"}

    for capabilities <- [%{}, %{"elicitation" => %{}}, %{"elicitation" => %{"form" => %{}}}],
        extra <- [
          %{},
          %{"requestState" => token, "inputResponses" => %{"url" => %{"action" => "cancel"}}}
        ] do
      context = %{mcp | client_capabilities: capabilities}

      assert {:error, :url_not_supported} =
               Test.read_resource(context, "company://url", request_state: token)

      {:reply, reply} =
        Dispatcher.dispatch(
          Server,
          message(context, Map.put(extra, "uri", "company://url")),
          mcp.assigns
        )

      assert reply["error"] == %{
               "code" => -32021,
               "message" => "Missing required client capability",
               "data" => %{"requiredCapabilities" => %{"elicitation" => %{"url" => %{}}}}
             }
    end

    refute_received {:handled, _, _, _}
  end

  defp message(mcp, extra) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "resources/read",
      "params" =>
        Map.merge(
          %{
            "uri" => "company://form",
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => mcp.client_capabilities
            }
          },
          extra
        )
    }
  end
end
