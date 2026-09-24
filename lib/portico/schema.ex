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
    check_dialect!(normalized)

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

  defp check_dialect!(schema) when is_map(schema) do
    case Map.get(schema, "$schema", @dialect) do
      @dialect -> :ok
      _ -> raise ArgumentError, "only Draft 2020-12 schemas are supported"
    end

    for keyword <- @schema_maps,
        children = schema[keyword],
        is_map(children),
        {_name, child} <- children,
        do: check_dialect!(child)

    for keyword <- @schema_lists,
        children = schema[keyword],
        is_list(children),
        child <- children,
        do: check_dialect!(child)

    for keyword <- @schema_values,
        Map.has_key?(schema, keyword),
        do: check_dialect!(schema[keyword])
  end

  defp check_dialect!(_schema), do: :ok
end
