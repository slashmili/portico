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
    options!(
      options,
      [:description, :input_schema, :output_schema, :elicitation_verifier, :annotations],
      "tool",
      env
    )

    schema = Keyword.get(options, :input_schema)

    unless is_map(schema) and not is_struct(schema) do
      error!(env, "expected :input_schema to be a plain map")
    end

    {schema, validator} = Portico.Schema.build!(schema, env)

    unless schema["type"] == "object" do
      error!(env, ~s(input_schema must declare type: "object" at the root))
    end

    verifier = Keyword.get(options, :elicitation_verifier, &Portico.Elicitation.verify/2)

    unless is_function(verifier, 2) and Function.info(verifier, :type) == {:type, :external} do
      error!(env, "expected :elicitation_verifier to be an external function capture of arity 2")
    end

    definition = %{input_schema: schema, validator: validator, elicitation_verifier: verifier}

    definition =
      case Keyword.fetch(options, :annotations) do
        :error ->
          definition

        {:ok, annotations} ->
          options!(
            annotations,
            [:read_only, :destructive, :idempotent, :open_world],
            "annotation",
            env
          )

          for {key, value} <- annotations do
            unless is_boolean(value),
              do: error!(env, "expected annotation #{inspect(key)} to be a boolean")
          end

          if annotations == [],
            do: definition,
            else: Map.put(definition, :annotations, Map.new(annotations))
      end

    definition =
      case Keyword.fetch(options, :output_schema) do
        :error ->
          definition

        {:ok, output_schema} ->
          unless is_map(output_schema) and not is_struct(output_schema),
            do: error!(env, "expected :output_schema to be a plain map")

          {output_schema, output_validator} =
            Portico.Schema.build!(output_schema, env, :output_schema)

          Map.merge(definition, %{
            output_schema: output_schema,
            output_validator: output_validator
          })
      end

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

  def prompt_metadata!(options, env) do
    options!(options, [:description, :arguments], "prompt", env)
    description!(options, env)
    arguments = Keyword.get(options, :arguments, [])

    unless Keyword.keyword?(arguments),
      do: error!(env, "expected prompt arguments to be a keyword list")

    options!(arguments, Keyword.keys(arguments), "prompt argument", env)

    arguments =
      Enum.map(arguments, fn {name, options} ->
        name = Atom.to_string(name)
        nonempty_string!(name, "prompt argument name", env)
        options!(options, [:description, :required], "prompt argument", env)
        description!(options, env)
        required = Keyword.get(options, :required, false)

        unless is_boolean(required),
          do: error!(env, "expected prompt argument :required to be a boolean")

        options |> Map.new() |> Map.merge(%{name: name, required: required})
      end)

    options |> Map.new() |> Map.put(:arguments, arguments)
  end

  def prompt!(name, module, env) do
    nonempty_string!(name, "prompt name", env)

    unless is_atom(module) and module not in [nil, true, false] and
             Code.ensure_compiled(module) == {:module, module} and
             function_exported?(module, :__portico_prompt__, 0) and
             function_exported?(module, :get, 2),
           do: error!(env, "expected a Portico.Prompt module")

    module
    |> Macro.compile_apply(:__portico_prompt__, [], env)
    |> Map.merge(%{name: name, module: module})
  end

  def prompt_catalog!(declarations) do
    Enum.reduce(declarations, MapSet.new(), fn {prompt, env}, names ->
      if MapSet.member?(names, prompt.name),
        do: error!(env, "duplicate prompt name #{inspect(prompt.name)}")

      MapSet.put(names, prompt.name)
    end)

    declarations |> Enum.map(fn {prompt, _} -> prompt end) |> Enum.sort_by(& &1.name)
  end

  defp description!(options, env) do
    if Keyword.has_key?(options, :description) and
         not (is_binary(options[:description]) and String.valid?(options[:description])),
       do: error!(env, "expected :description to be a UTF-8 string")
  end

  def resource_metadata!(options, env) do
    options!(options, [:name, :description, :mime_type, :elicitation_verifier], "resource", env)
    nonempty_string!(options[:name], "resource name", env)

    for {key, value} <- options, key != :elicitation_verifier do
      unless is_binary(value) and String.valid?(value),
        do: error!(env, "expected resource #{inspect(key)} to be a UTF-8 string")
    end

    verifier = Keyword.get(options, :elicitation_verifier, &Portico.Elicitation.verify/2)

    unless is_function(verifier, 2) and Function.info(verifier, :type) == {:type, :external},
      do:
        error!(
          env,
          "expected :elicitation_verifier to be an external function capture of arity 2"
        )

    Map.put(Map.new(options), :elicitation_verifier, verifier)
  end

  def resource!(uri, module, env) do
    unless Portico.Resource.valid_uri?(uri),
      do: error!(env, "expected resource URI to be an absolute URI without template variables")

    resource_module!(module, env) |> Map.merge(%{uri: uri, module: module})
  end

  def resource_template!(uri_template, module, env) do
    case Portico.Resource.Template.build(uri_template) do
      {:ok, matcher} ->
        resource_module!(module, env)
        |> Map.merge(%{uri_template: uri_template, module: module, matcher: matcher})

      {:error, _} ->
        error!(env, "expected a resource URI template with simple whole-path-segment variables")
    end
  end

  def resource_template_catalog!(declarations) do
    Enum.reduce(declarations, MapSet.new(), fn {resource, env}, shapes ->
      if MapSet.member?(shapes, resource.matcher.shape),
        do: error!(env, "duplicate resource template shape #{inspect(resource.uri_template)}")

      MapSet.put(shapes, resource.matcher.shape)
    end)

    declarations |> Enum.map(fn {resource, _} -> resource end) |> Enum.sort_by(& &1.uri_template)
  end

  defp resource_module!(module, env) do
    unless is_atom(module) and module not in [nil, true, false] and
             Code.ensure_compiled(module) == {:module, module} and
             function_exported?(module, :__portico_resource__, 0) and
             function_exported?(module, :read, 1),
           do: error!(env, "expected a Portico.Resource module")

    module
    |> Macro.compile_apply(:__portico_resource__, [], env)
  end

  def resource_catalog!(declarations) do
    Enum.reduce(declarations, MapSet.new(), fn {resource, env}, uris ->
      if MapSet.member?(uris, resource.uri),
        do: error!(env, "duplicate resource URI #{inspect(resource.uri)}")

      MapSet.put(uris, resource.uri)
    end)

    declarations |> Enum.map(fn {resource, _} -> resource end) |> Enum.sort_by(& &1.uri)
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
