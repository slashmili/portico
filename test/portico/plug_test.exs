defmodule Portico.PlugTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  # Exercise adapter outcomes that Plug.Test's in-memory reader cannot produce.
  defmodule BodyAdapter do
    def read_req_body(%{read_error: reason}, _options), do: {:error, reason}

    def read_req_body(state, options) do
      Plug.Adapters.Test.Conn.read_req_body(state, Keyword.put(options, :length, 17))
    end

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
  end

  defmodule Echo do
    use Portico.Tool, input_schema: %{type: "object"}
    @impl true
    def call(%{"fail" => true}, _request) do
      Portico.Result.error("Try another value")
    end

    def call(arguments, request) do
      if pid = request.assigns[:observer], do: send(pid, {:called, request})
      if arguments["raise"], do: raise("private detail")
      Portico.Result.text(arguments["text"] || "hello")
    end
  end

  defmodule Server do
    use Portico.Server, name: "http-test", version: "1"
    tool "echo", Echo
  end

  defp message(method \\ "tools/call") do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => method,
      "params" => %{
        "name" => "echo",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp post(message) do
    conn(:post, "/mcp", JSON.encode!(message))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", message["method"] || "tools/call")
    |> put_req_header("mcp-name", "echo")
  end

  defp run(conn, options \\ []) do
    Portico.Plug.call(conn, Portico.Plug.init(Keyword.merge([server: Server], options)))
  end

  defp error(conn, status, code) do
    assert conn.status == status
    assert conn.halted
    assert JSON.decode!(conn.resp_body)["error"]["code"] == code
  end

  test "serves discovery, listing and completed tool calls as JSON" do
    for method <- ["server/discover", "tools/list", "tools/call"] do
      result = message(method) |> post() |> run()
      assert result.status == 200
      assert result.halted
      assert get_resp_header(result, "content-type") == ["application/json; charset=utf-8"]

      assert %{"id" => 7, "result" => %{"resultType" => "complete"} = body} =
               JSON.decode!(result.resp_body)

      case method do
        "server/discover" -> assert body["supportedVersions"] == ["2026-07-28"]
        "tools/list" -> assert [%{"name" => "echo"}] = body["tools"]
        "tools/call" -> assert body["content"] == [%{"type" => "text", "text" => "hello"}]
      end
    end
  end

  test "passes only explicitly selected assigns into a fresh request" do
    conn = message() |> post() |> assign(:observer, self()) |> assign(:secret, "private")
    assert run(conn).status == 200
    refute_received {:called, _}

    for _ <- 1..2 do
      assert run(conn, assigns: [:observer]).status == 200
      assert_received {:called, request}
      assert request.assigns == %{observer: self()}
      assert request.id == 7
    end
  end

  test "accepts parser-decoded bodies and never merges query parameters" do
    parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)
    parsed = message() |> post() |> Plug.Parsers.call(parsers)
    assert run(parsed).status == 200
    poisoned = %{parsed | body_params: Map.delete(parsed.body_params, "id"), params: message()}
    assert run(poisoned).status == 202
  end

  test "checks origin on every method, with absent origin allowed and exact matches only" do
    base = message() |> post()
    assert run(base).status == 200
    assert run(put_req_header(base, "origin", "https://client.test")).status == 403

    assert run(put_req_header(base, "origin", "https://client.test"),
             allowed_origins: ["https://client.test"]
           ).status == 200

    assert run(put_req_header(base, "origin", "https://client.test.evil"),
             allowed_origins: ["https://client.test"]
           ).status == 403

    duplicated = %{
      base
      | req_headers: [
          {"origin", "https://client.test"},
          {"origin", "https://client.test"} | base.req_headers
        ]
    }

    assert run(duplicated, allowed_origins: ["https://client.test"]).status == 403

    assert conn(:get, "/mcp") |> put_req_header("origin", "null") |> run() |> Map.fetch!(:status) ==
             403
  end

  test "rejects non-POST methods with Allow and halts" do
    for method <- [:get, :delete, :put, :head, :options] do
      result = conn(method, "/mcp") |> run()
      assert result.status == 405
      assert result.halted
      assert get_resp_header(result, "allow") == ["POST"]
    end
  end

  test "requires JSON content type" do
    base = post(message())

    for value <- ["text/plain", "application/jsonp", "invalid"] do
      assert run(put_req_header(base, "content-type", value)).status == 415
    end

    assert run(delete_req_header(base, "content-type")).status == 415

    assert run(put_req_header(base, "content-type", "application/json; charset=utf-8")).status ==
             200
  end

  test "requires both explicit Accept types with positive quality" do
    base = post(message())

    for value <- [
          "*/*",
          "application/json",
          "text/event-stream",
          "application/json, text/event-stream;q=0",
          "application/json;q=oops, text/event-stream"
        ] do
      assert run(put_req_header(base, "accept", value)).status == 406
    end

    assert run(delete_req_header(base, "accept")).status == 406

    assert run(put_req_header(base, "accept", "text/event-stream;q=0.5, application/json")).status ==
             200
  end

  test "returns parse errors without an invented ID" do
    base = post(message())
    {adapter, state} = conn(:post, "/mcp", "{").adapter
    result = run(%{base | adapter: {adapter, state}})
    error(result, 400, -32700)
    refute Map.has_key?(JSON.decode!(result.resp_body), "id")
  end

  test "rejects batches, responses, invalid envelopes and missing metadata" do
    for body <- [
          [],
          [message()],
          %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}},
          %{"id" => nil}
        ] do
      result = post(message())
      invalid = conn(:post, "/mcp", JSON.encode!(body))
      error(run(%{result | adapter: invalid.adapter}), 400, -32600)
    end

    error(message() |> Map.delete("params") |> post() |> run(), 400, -32602)
  end

  test "validates headers before invoking application code" do
    base = post(message()) |> assign(:observer, self())

    for header <- ["mcp-protocol-version", "mcp-method", "mcp-name"] do
      result = base |> delete_req_header(header) |> run(assigns: [:observer])
      error(result, 400, -32020)
      assert JSON.decode!(result.resp_body)["id"] == 7
      error(base |> put_req_header(header, "wrong") |> run(assigns: [:observer]), 400, -32020)
    end

    refute_received {:called, _}
  end

  test "expected tool failures are completed results with HTTP 200" do
    result = message() |> put_in(["params", "arguments"], %{"fail" => true}) |> post() |> run()
    assert result.status == 200
    response = JSON.decode!(result.resp_body)
    refute Map.has_key?(response, "error")
    assert response["id"] == 7
    assert response["result"]["resultType"] == "complete"
    assert response["result"]["isError"] == true
    assert response["result"]["content"] == [%{"type" => "text", "text" => "Try another value"}]
  end

  test "maps protocol errors to HTTP statuses" do
    old = put_in(message(), ["params", "_meta", "io.modelcontextprotocol/protocolVersion"], "old")
    error(old |> post() |> put_req_header("mcp-protocol-version", "old") |> run(), 400, -32022)
    error(message("unknown") |> post() |> run(), 404, -32601)
    missing = put_in(message(), ["params", "name"], "missing")
    error(missing |> post() |> put_req_header("mcp-name", "missing") |> run(), 400, -32602)
    broken = put_in(message(), ["params", "arguments", "raise"], true)
    result = broken |> post() |> run()
    error(result, 500, -32603)
    refute result.resp_body =~ "private detail"
  end

  test "ignores valid notifications with an empty 202 response" do
    result = message() |> Map.delete("id") |> post() |> delete_req_header("mcp-method") |> run()
    assert result.status == 202
    assert result.resp_body == ""
    assert result.halted
  end

  test "enforces the raw body limit including exact boundary" do
    body = message()
    size = byte_size(JSON.encode!(body))
    assert run(post(body), max_body_bytes: size).status == 200
    assert run(post(body), max_body_bytes: size - 1).status == 413
  end

  test "assembles successive reads in order and bounds their total size" do
    body = put_in(message(), ["params", "arguments", "text"], "multiple chunks: Grüße")
    base = post(body)
    {_adapter, state} = base.adapter
    chunked = %{base | adapter: {BodyAdapter, state}}
    result = run(chunked)
    assert result.status == 200

    assert get_in(JSON.decode!(result.resp_body), ["result", "content"]) ==
             [%{"type" => "text", "text" => "multiple chunks: Grüße"}]

    assert run(chunked, max_body_bytes: byte_size(JSON.encode!(body)) - 1).status == 413
  end

  test "read failures halt without dispatching a partial message" do
    base = post(message()) |> assign(:observer, self())
    {_adapter, state} = base.adapter

    for {reason, status} <- [timeout: 408, closed: 400] do
      failing = %{base | adapter: {BodyAdapter, Map.put(state, :read_error, reason)}}
      result = run(failing, assigns: [:observer])
      assert result.status == status
      assert result.halted
      refute_received {:called, _}
    end
  end

  test "uses Logger's level to suppress debug requests" do
    # A process-local threshold exercises Logger filtering without changing
    # application-wide configuration during concurrent tests.
    Logger.put_process_level(self(), :info)

    try do
      assert capture_log(fn -> assert run(post(message())).status == 200 end) == ""
    after
      Logger.delete_process_level(self())
    end
  end

  test "logs raw and parser-decoded requests with recursive parameter filtering" do
    arguments = %{
      "text" => "visible",
      "Password" => "password-value",
      "nested" => [%{"access_token" => "token-value", "email" => "email-value"}],
      "api_key" => "key-value"
    }

    body = put_in(message(), ["params", "arguments"], arguments)
    parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON)

    for conn <- [post(body), post(body) |> Plug.Parsers.call(parsers)] do
      conn = conn |> assign(:observer, self()) |> assign(:private, "assign-value")

      log =
        capture_log(fn ->
          response =
            run(conn, filter_parameters: ["EMAIL", "text"], assigns: [:observer])

          assert response.status == 200

          assert JSON.decode!(response.resp_body)["result"]["content"] ==
                   [%{"type" => "text", "text" => "visible"}]
        end)

      assert log =~ "[debug]"
      assert log =~ ~s|Processing MCP "tools/call" (id=7)|
      assert log =~ "Parameters:"
      refute log =~ "visible"
      assert log =~ "[FILTERED]"

      for secret <- ["password-value", "token-value", "email-value", "key-value", "assign-value"] do
        refute log =~ secret
      end

      assert_received {:called, _request}
    end
  end

  test "logs at debug without extra options and skips malformed envelopes" do
    log = capture_log(fn -> assert run(post(message())).status == 200 end)
    assert log =~ "[debug]"

    assert capture_log(fn ->
             error(run(post(%{"method" => "tools/call"})), 400, -32600)
           end) == ""
  end

  test "validates configuration at initialization" do
    for options <- [
          [],
          [server: nil],
          [server: Server, allowed_origins: "*"],
          [server: Server, assigns: ["user"]],
          [server: Server, max_body_bytes: 0],
          [server: Server, typo: true],
          [server: Server, log: :debug],
          [server: Server, filter_parameters: "password"],
          [server: Server, filter_parameters: [:email]],
          [server: Server, filter_parameters: [""]]
        ] do
      assert_raise ArgumentError, fn -> Portico.Plug.init(options) end
    end
  end
end
