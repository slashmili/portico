defmodule Portico.Schema do
  @moduledoc false

  # JSV is an implementation detail of this module. Callers treat validators
  # as opaque values; tool metadata and wire schemas stay ordinary JSON maps.

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @build_options [default_meta: @dialect, resolver: [], atoms: false, formats: false]
  @meta_validator JSV.build!(%{"$ref" => @dialect}, @build_options)

  # These keywords contain schemas. Annotation values such as const/default
  # are JSON data and must not be interpreted as schema declarations.
  @schema_maps ["$defs", "definitions", "properties", "patternProperties", "dependentSchemas"]
  @schema_lists ["allOf", "anyOf", "oneOf", "prefixItems"]
  @schema_values [
    "items",
    "additionalProperties",
    "unevaluatedProperties",
    "unevaluatedItems",
    "contains",
    "propertyNames",
    "not",
    "if",
    "then",
    "else",
    "contentSchema"
  ]

  def build!(schema, env) do
    normalized = normalize(schema)
    check_schema!(normalized)

    case JSV.validate(normalized, @meta_validator, cast: false) do
      {:ok, _} -> :ok
      {:error, _} -> raise ArgumentError, "does not satisfy the Draft 2020-12 meta-schema"
    end

    case JSV.build(normalized, @build_options) do
      {:ok, validator} ->
        {normalized, validator}

      {:error, reason} ->
        raise ArgumentError, "cannot build validator: #{Exception.message(reason)}"
    end
  rescue
    error in ArgumentError ->
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "invalid :input_schema: #{Exception.message(error)}"
  end

  def valid?(validator, data) do
    match?({:ok, _}, JSV.validate(data, validator, cast: false))
  end

  # Return only Portico-owned text. Validator messages can include input values.
  def validate(validator, data) do
    case JSV.validate(data, validator, cast: false) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        details =
          error.errors
          |> Enum.flat_map(&diagnostics/1)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.join("; ")

        {:error, "Tool arguments do not match the input schema. " <> details}
    end
  end

  # Container errors accompany the more specific errors at their child paths.
  defp diagnostics(%{kind: kind})
       when kind in [:properties, :patternProperties, :additionalProperties, :items, :prefixItems],
       do: []

  defp diagnostics(%{kind: :required, args: args, data_path: path}) do
    Enum.map(args[:required], &diagnostic([&1 | path], "is required"))
  end

  defp diagnostics(%{kind: :type, args: args, data_path: path}) do
    types = args[:type] |> List.wrap() |> Enum.map_join(" or ", &to_string/1)
    [diagnostic(path, "expected " <> types)]
  end

  defp diagnostics(%{kind: :boolean_schema, data_path: path}),
    do: [diagnostic(path, "is not allowed")]

  defp diagnostics(%{kind: kind, data_path: path}) do
    # Keep compositions as a single constraint: alternative branches are not
    # individually required. Never expose validator-specific error messages.
    keyword = if kind == :jsv@if, do: "conditional", else: to_string(kind)
    [diagnostic(path, "does not satisfy " <> keyword)]
  end

  defp diagnostic(path, reason) do
    pointer =
      path
      |> Enum.reverse()
      |> Enum.map_join("", fn segment ->
        "/" <> (segment |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1"))
      end)

    # JSON quoting also escapes control characters in property names.
    case Portico.Protocol.Encoder.json(pointer) do
      {:ok, quoted} -> quoted <> ": " <> reason
      {:error, :invalid_json} -> "Invalid property path: " <> reason
    end
  end

  defp normalize(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn {key, value}, result ->
      key = normalize_key(key)

      if Map.has_key?(result, key),
        do: raise(ArgumentError, "duplicate key after normalization: #{inspect(key)}")

      Map.put(result, key, normalize(value))
    end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_binary(value) do
    if String.valid?(value), do: value, else: raise(ArgumentError, "expected UTF-8 strings")
  end

  defp normalize(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp normalize(_value), do: raise(ArgumentError, "expected JSON values and plain maps")

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: normalize(key)
  defp normalize_key(_key), do: raise(ArgumentError, "expected atom or string map keys")

  defp check_schema!(schema) when is_map(schema) do
    if Map.has_key?(schema, "x-mcp-header") do
      raise ArgumentError,
            "x-mcp-header is not supported; remove the annotation from the input schema " <>
              "until Portico supports custom MCP parameter header validation"
    end

    case Map.get(schema, "$schema", @dialect) do
      @dialect -> :ok
      _ -> raise ArgumentError, "only Draft 2020-12 schemas are supported"
    end

    for keyword <- @schema_maps,
        children = schema[keyword],
        is_map(children),
        {_name, child} <- children,
        do: check_schema!(child)

    for keyword <- @schema_lists,
        children = schema[keyword],
        is_list(children),
        child <- children,
        do: check_schema!(child)

    for keyword <- @schema_values,
        Map.has_key?(schema, keyword),
        do: check_schema!(schema[keyword])
  end

  defp check_schema!(_schema), do: :ok
end
