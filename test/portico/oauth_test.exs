defmodule Portico.OAuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  defp options(overrides \\ []) do
    [
      resource: "https://mcp.example/api/mcp",
      authorization_servers: ["https://auth.example"],
      scopes: ["mcp:access"],
      verify_token: fn _, _ -> {:ok, %{current_user: 42}} end
    ]
    |> Keyword.merge(overrides)
    |> Portico.OAuth.init()
  end

  defp request(header), do: conn(:post, "/api/mcp") |> put_req_header("authorization", header)

  test "valid bearer credentials receive context and add assigns without consuming the body" do
    verifier = fn token, context ->
      assert token == "a_b.c~d+/=="
      assert context == %{resource: "https://mcp.example/api/mcp", scopes: ["mcp:access"]}
      {:ok, %{current_user: 42}}
    end

    conn =
      conn(:post, "/api/mcp", "body")
      |> put_req_header("authorization", "bEaReR  a_b.c~d+/==")
      |> assign(:existing, true)
      |> Portico.OAuth.call(options(verify_token: verifier))

    refute conn.halted
    assert conn.assigns == %{current_user: 42, existing: true}
    assert {:ok, "body", _} = read_body(conn)
  end

  test "missing credentials challenge without invoking verifier or exposing query/body tokens" do
    opts = options(verify_token: fn _, _ -> flunk("must not verify") end)

    for conn <- [
          conn(:post, "/api/mcp?access_token=secret", "access_token=secret"),
          request("Basic secret")
        ] do
      conn = Portico.OAuth.call(conn, opts)
      assert conn.status == 401 and conn.halted

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/api/mcp", scope="mcp:access")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert conn.resp_body == ""
    end
  end

  test "malformed or duplicate credentials are rejected before verification" do
    opts = options(verify_token: fn _, _ -> flunk("must not verify") end)

    duplicates = %{
      conn(:post, "/api/mcp")
      | req_headers: [{"authorization", "Bearer a"}, {"authorization", "Bearer b"}]
    }

    for conn <- [
          duplicates
          | Enum.map(
              ["Bearer", "Bearer ", "Bearer a b", "Bearer a,b", "Bearer =", "Bearer\ta"],
              &request/1
            )
        ] do
      conn = Portico.OAuth.call(conn, opts)
      assert conn.status == 400 and conn.halted
      assert hd(get_resp_header(conn, "www-authenticate")) =~ ~s(error="invalid_request")
    end
  end

  test "verifier errors become HTTP errors and scope challenges" do
    for {reason, status} <- [
          invalid_token: 401,
          insufficient_scope: 403,
          temporarily_unavailable: 503
        ] do
      opts = options(verify_token: fn _, _ -> {:error, reason} end)
      conn = Portico.OAuth.call(request("Bearer secret"), opts)
      assert conn.status == status and conn.halted
      assert conn.resp_body == ""

      if status != 503 do
        assert hd(get_resp_header(conn, "www-authenticate")) =~ ~s(error="#{reason}")
      else
        assert get_resp_header(conn, "www-authenticate") == []
      end
    end
  end

  test "bad callback results and crashes fail closed without leaking details" do
    callbacks =
      [
        fn _, _ -> raise "private secret" end,
        fn _, _ -> throw("private secret") end,
        fn _, _ -> exit("private secret") end
      ] ++
        Enum.map(
          [:ok, {:ok, nil}, {:ok, %{"user" => 1}}, {:ok, %URI{}}, {:error, "private secret"}],
          fn value -> fn _, _ -> value end end
        )

    for callback <- callbacks do
      log =
        capture_log(fn ->
          conn = Portico.OAuth.call(request("Bearer secret"), options(verify_token: callback))
          assert conn.status == 500 and conn.halted
          assert conn.resp_body == ""
        end)

      assert log =~ "Portico OAuth verifier failed"
      refute log =~ "secret"
    end
  end

  test "public metadata uses configured URLs and exposes no credentials" do
    opts = options()

    conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/mcp")
      |> Map.put(:host, "untrusted.example")
      |> Portico.OAuth.metadata(opts)

    assert conn.status == 200 and conn.halted

    assert JSON.decode!(conn.resp_body) == %{
             "resource" => "https://mcp.example/api/mcp",
             "authorization_servers" => ["https://auth.example"],
             "scopes_supported" => ["mcp:access"],
             "bearer_methods_supported" => ["header"]
           }

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    head = Portico.OAuth.metadata(conn(:head, "/metadata"), opts)
    assert head.status == 200 and head.resp_body == ""
    post = Portico.OAuth.metadata(conn(:post, "/metadata"), opts)
    assert post.status == 405 and post.halted
    assert get_resp_header(post, "allow") == ["GET, HEAD"]
  end

  test "root metadata paths, loopback development and empty scopes" do
    for url <- [
          "https://mcp.example",
          "https://mcp.example/",
          "http://localhost:4000",
          "http://127.0.0.1:4000",
          "http://[::1]:4000"
        ] do
      opts = options(resource: url, scopes: [])
      assert String.ends_with?(opts.metadata_url, "/.well-known/oauth-protected-resource")
      conn = Portico.OAuth.call(conn(:post, "/mcp"), opts)
      refute hd(get_resp_header(conn, "www-authenticate")) =~ "scope="
    end
  end

  test "already halted connections stay halted and untouched" do
    conn = conn(:post, "/") |> send_resp(418, "stop") |> halt()
    assert Portico.OAuth.call(conn, options()) == conn
    assert Portico.OAuth.metadata(conn, options()) == conn
  end

  test "configuration errors fail at init" do
    for url <- [
          nil,
          3,
          "",
          "/mcp",
          "http://public.example/mcp",
          "https:///mcp",
          "https://x:0",
          "https://x:99999",
          "https://user@x",
          "https://x?q=a",
          "https://x#fragment",
          "https://x/\"",
          "https://x/\\",
          "https://x/\n"
        ] do
      assert_raise ArgumentError, fn -> options(resource: url) end
    end

    for overrides <- [
          [authorization_servers: []],
          [authorization_servers: nil],
          [authorization_servers: ["bad"]],
          [scopes: nil],
          [scopes: ["a", "a"]],
          [scopes: [""]],
          [scopes: ["a b"]],
          [scopes: ["a\""]],
          [scopes: ["a\\"]],
          [scopes: [1]],
          [verify_token: nil],
          [verify_token: fn _ -> :ok end],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> options(overrides) end
    end

    assert_raise ArgumentError, fn ->
      Portico.OAuth.init(resource: "https://x", resource: "https://y")
    end
  end
end
