defmodule Portico.Server.Compiler do
  @moduledoc false

  def info!(options, env) do
    options!(options, [:name, :version], "server", env)

    for key <- [:name, :version], into: %{} do
      value = Keyword.get(options, key)
      nonempty_string!(value, inspect(key), env)
      {key, value}
    end
  end

  def tool!(name, module, env) do
    nonempty_string!(name, "tool name", env)

    unless is_atom(module) and module not in [nil, true, false] do
      error!(env, "expected a Portico.Tool module")
    end

    case Code.ensure_compiled(module) do
      {:module, _} -> :ok
      {:error, _} -> error!(env, "could not compile tool module #{inspect(module)}")
    end

    unless function_exported?(module, :__portico_tool__, 0) and
             function_exported?(module, :call, 2) do
      error!(env, "expected #{inspect(module)} to use Portico.Tool")
    end

    module
    |> Macro.compile_apply(:__portico_tool__, [], env)
    |> Map.merge(%{name: name, module: module})
  end

  def tool_metadata!(options, env) do
    options!(options, [:description, :input_schema], "tool", env)
    schema = Keyword.get(options, :input_schema)

    unless is_map(schema) and not is_struct(schema) do
      error!(env, "expected :input_schema to be a plain map")
    end

    {schema, validator} = Portico.Schema.build!(schema, env)
    definition = %{input_schema: schema, validator: validator}

    case Keyword.fetch(options, :description) do
      {:ok, description} ->
        unless is_binary(description) and String.valid?(description) do
          error!(env, "expected :description to be a UTF-8 string")
        end

        Map.put(definition, :description, description)

      :error ->
        definition
    end
  end

  def catalog!(declarations) do
    Enum.reduce(declarations, MapSet.new(), fn {tool, env}, names ->
      if MapSet.member?(names, tool.name) do
        error!(env, "duplicate tool name #{inspect(tool.name)}")
      end

      MapSet.put(names, tool.name)
    end)

    declarations
    |> Enum.map(fn {tool, _env} -> tool end)
    |> Enum.sort_by(& &1.name)
  end

  defp options!(options, allowed, kind, env) do
    unless Keyword.keyword?(options) do
      error!(env, "expected #{kind} options to be a keyword list")
    end

    Enum.reduce(options, MapSet.new(), fn {key, _value}, seen ->
      unless key in allowed do
        error!(env, "unknown #{kind} option #{inspect(key)}")
      end

      if MapSet.member?(seen, key) do
        error!(env, "duplicate #{kind} option #{inspect(key)}")
      end

      MapSet.put(seen, key)
    end)
  end

  defp nonempty_string!(value, label, env) do
    unless is_binary(value) and value != "" and String.valid?(value) do
      error!(env, "expected #{label} to be a nonempty UTF-8 string")
    end
  end

  defp error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
