defmodule Portico.ResourceDeclarationTest do
  use ExUnit.Case, async: true

  defp compile_resource(options, callback \\ true) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")
    body = if callback, do: quote(do: def(read(_), do: Portico.Resource.text(""))), else: nil

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Resource, unquote(Macro.escape(options))
          unquote(body)
        end
      end
    )

    module
  end

  defp compile_server(uri, resource, duplicate \\ false) do
    module = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    extra = if duplicate, do: quote(do: resource(unquote(uri), unquote(resource))), else: nil

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Server, name: "test", version: "1"
          resource unquote(Macro.escape(uri)), unquote(resource)
          unquote(extra)
        end
      end
    )

    module
  end

  test "declaration errors fail at compilation" do
    for options <- [
          [],
          %{},
          [name: nil],
          [name: ""],
          [name: "a", name: "b"],
          [name: "x", title: "unsupported"],
          [name: "x", mime_type: 1],
          [name: "x", description: <<255>>]
        ] do
      assert_raise CompileError, fn -> compile_resource(options) end
    end

    assert_raise CompileError, ~r/read\/1/, fn -> compile_resource([name: "missing"], false) end
    resource = compile_resource(name: "valid")

    for uri <- [
          nil,
          "",
          "/relative",
          "company://{id}",
          "company://bad space",
          "company://bad%zz",
          <<255>>
        ] do
      assert_raise CompileError, ~r/resource URI/, fn -> compile_server(uri, resource) end
    end

    for module <- [nil, false, "not a module", String, MissingResourceModule] do
      assert_raise CompileError, ~r/Portico.Resource module/, fn ->
        compile_server("company://test", module)
      end
    end

    assert_raise CompileError, ~r/duplicate resource URI/, fn ->
      compile_server("company://test", resource, true)
    end
  end

  test "custom and file URIs are declarations, not automatic reads" do
    resource = compile_resource(name: "empty")

    for uri <- ["file:///not-a-real-file", "urn:example:handbook", "company://handbook"] do
      server = compile_server(uri, resource)

      assert {:ok, %Portico.Resource{text: "", uri: ^uri, mime_type: nil}} =
               Portico.Test.read_resource(server, uri)
    end
  end
end
