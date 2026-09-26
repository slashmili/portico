defmodule Portico.PromptDeclarationTest do
  use ExUnit.Case, async: true

  defp compile_prompt(options, callback \\ true) do
    module = Module.concat(__MODULE__, "Prompt#{System.unique_integer([:positive])}")
    body = if callback, do: quote(do: def(get(_, _), do: Portico.Prompt.text("")))

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Prompt, unquote(Macro.escape(options))
          unquote(body)
        end
      end
    )

    module
  end

  defp compile_server(name, prompt, duplicate \\ false) do
    module = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    extra = if duplicate, do: quote(do: prompt(unquote(name), unquote(prompt)))

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Portico.Server, name: "test", version: "1"
          prompt unquote(Macro.escape(name)), unquote(prompt)
          unquote(extra)
        end
      end
    )
  end

  test "invalid metadata, arguments and missing callbacks fail at compilation" do
    for options <- [
          %{},
          [unknown: true],
          [description: nil],
          [description: <<255>>],
          [arguments: %{}],
          [arguments: [x: [], x: []]],
          [arguments: ["": []]],
          [arguments: [x: nil]],
          [arguments: [x: [required: nil]]],
          [arguments: [x: [description: 42]]],
          [arguments: [x: [required: true, required: false]]],
          [arguments: [x: [schema: %{}]]]
        ] do
      assert_raise CompileError, fn -> compile_prompt(options) end
    end

    assert_raise CompileError, ~r/get\/2/, fn -> compile_prompt([], false) end
  end

  test "routes validate names, implementing modules and duplicates" do
    prompt = compile_prompt([])

    for name <- [nil, "", 42, <<255>>] do
      assert_raise CompileError, fn -> compile_server(name, prompt) end
    end

    for module <- [nil, false, "bad", String, UnknownPromptModule] do
      assert_raise CompileError, fn -> compile_server("name", module) end
    end

    assert_raise CompileError, ~r/duplicate prompt name/, fn ->
      compile_server("name", prompt, true)
    end
  end
end
