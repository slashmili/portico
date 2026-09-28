# Overview

Portico is an Elixir [MCP server](https://modelcontextprotocol.io/docs/2026-07-28/learn/server-concepts) library with module-based tool routing, request context,
Plug integration, and ExUnit helpers. It targets the [2026-07-28](https://blog.modelcontextprotocol.io/posts/2026-07-28/) specification.

> #### Clients {: .warning}
> This means [clients](https://modelcontextprotocol.io/docs/2026-07-28/learn/client-concepts) need to support this version. At the time of writing, opencode2, Codex, and Claude support this specification, but they need to be configured to use version `2026-07-28`.

This page aims to get you started using Portico. For full documentation on the supported features, see each specific module.

* [Tools](tbd)
* ...

## Installation

You need an Elixir application with Plug or Phoenix.

Add the dependency to your `mix.exs` and run `mix deps.get`:

```elixir
{:portico, "~> 0.1"}
```

## Getting started

We want to offer a tool called `add` that adds two integers. Let's start by writing a test to describe the expected behavior:

```elixir
defmodule MyApp.Tools.AddTest do
  use Portico.Test, server: MyApp.MCP, async: true

  test "adds integers", %{mcp: mcp} do
    assert {:ok, result} = call_tool(mcp, "add", %{"a" => 2, "b" => 3})
    assert_text result, "5"
  end
end
```

If you run the test, it fails with:

```
mix test
  1) test adds integers (MyApp.Tools.AddTest)
     test/my_app/tools/add_test.exs:4
     match (=) failed
     code:  assert {:ok, result} = call_tool(mcp, "add", %{"a" => 2, "b" => 3})
     left:  {:ok, result}
     right: {:error, :invalid_server}
     stacktrace:
       test/my_app/tools/add_test.exs:5: (test)

..
Finished in 0.01 seconds (0.01s async, 0.00s sync)

Result: 2/3 passed (1/1 doctest, 1/2 tests)
Failed: 1 test
```

We haven't added the server module yet. Let's add it:

```elixir
defmodule MyApp.MCP do
  use Portico.Server, name: "my-app", version: "0.1.0"
end
```

If you run the test again, it should now fail with the error `unknown_tool`:

```
mix test
  1) test adds integers (MyApp.Tools.AddTest)
     test/my_app/tools/add_test.exs:4
     match (=) failed
     code:  assert {:ok, result} = call_tool(mcp, "add", %{"a" => 2, "b" => 3})
     left:  {:ok, result}
     right: {:error, :unknown_tool}
     stacktrace:
       test/my_app/tools/add_test.exs:5: (test)

..
Finished in 0.02 seconds (0.02s async, 0.00s sync)

Result: 2/3 passed (1/1 doctest, 1/2 tests)
Failed: 1 test
```

Now we can add the tool implementation and its route:

```elixir

defmodule MyApp.Tools.Add do
  use Portico.Tool,
    description: "Add two integers.",
    input_schema: %{
      type: "object",
      properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
      required: ["a", "b"],
      additionalProperties: false
    }

  @impl true
  def call(%{"a" => a, "b" => b}, _request) do
    {:ok, result} = Portico.Result.text(Integer.to_string(trunc(a) + trunc(b)))

    {:ok, result}
  end
end

defmodule MyApp.MCP do
  use Portico.Server, name: "my-app", version: "0.1.0"

  tool "add", MyApp.Tools.Add
end
```

The test should now pass.

Here we are returning text. We can improve this by returning a structured result:

```elixir
defmodule MyApp.Tools.Add do
  use Portico.Tool,
    description: "Add two integers.",
    input_schema: %{
      type: "object",
      properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
      required: ["a", "b"],
      additionalProperties: false
    },
    output_schema: %{
      type: "object",
      properties: %{result: %{type: "integer"}},
      required: ["result"],
      additionalProperties: false
    }

  @impl true
  def call(%{"a" => a, "b" => b}, _request) do
    {:ok, result} = Portico.Result.text(Integer.to_string(trunc(a) + trunc(b)))

    {:ok, result}
  end
end

defmodule MyApp.MCP do
  use Portico.Server, name: "my-app", version: "0.1.0"

  tool "add", MyApp.Tools.Add
end
```

If you run the test, you'll see that it fails again with the error `invalid_output`. Portico checks the input and output against their schemas and reports a failure when the implementation doesn't match:

```
mix test

  1) test adds integers (MyApp.Tools.AddTest)
     test/my_app/tools/add_test.exs:4
     match (=) failed
     code:  assert {:ok, result} = call_tool(mcp, "add", %{"a" => 2, "b" => 3})
     left:  {:ok, result}
     right: {:error, :invalid_output}
     stacktrace:
       test/my_app/tools/add_test.exs:5: (test)

..
Finished in 0.02 seconds (0.02s async, 0.00s sync)

Result: 2/3 passed (1/1 doctest, 1/2 tests)
Failed: 1 test
```

To fix that, change the `call/2` function to return a structured result:

```elixir
defmodule MyApp.Tools.Add do
...
  def call(%{"a" => a, "b" => b}, _request) do
    {:ok, result} =
      Portico.Result.structured(%{
        result: a + b
      })

    {:ok, result}
  end
...
```

The test should still fail because it expects text, while the result now contains a JSON object. Update the assertion:

```elixir
defmodule MyApp.Tools.AddTest do
  use Portico.Test, server: MyApp.MCP, async: true

  test "adds integers", %{mcp: mcp} do
    assert {:ok, result} = call_tool(mcp, "add", %{"a" => 2, "b" => 3})

    assert result.structured_content == %{"result" => 5}
  end
end
```

The last step is to expose this tool through an API. You can use Plug or Phoenix:

<!-- tabs-open -->

### Plug

```elixir
defmodule MyApp.Router do
..
  match "/mcp" do
    options = Portico.Plug.init(server: MyApp.MCP)

    Portico.Plug.call(conn, options)
  end
...
end

```

### Phoenix

```elixir
defmodule MyApp.Router do
...
forward "/mcp", Portico.Plug,
  server: MyApp.MCP,
  allowed_origins: [""]
...
end
```

<!-- tabs-close -->

Run your application, then use the official Inspector to try out the tool call:

```sh
npx @modelcontextprotocol/inspector \
          --server-url http://127.0.0.1:4000/mcp \
          --transport http \
          --protocol-era modern
```
