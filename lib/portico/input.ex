defmodule Portico.Input do
  @moduledoc """
  A form requested by a tool with `{:ok, form, request_state}`.

  `form/2` validates and normalizes a flat JSON Schema with string, number,
  integer, or boolean fields, single-choice string enums, and arrays of string
  enum choices, with optional labels for each choice. Nested objects, references,
  and URL mode are not supported. Errors return tuples.

  Portico protects the form and application state in an expiring signed token.
  Accepted answers are validated against that form before `handle_input/3` runs.
  No state, schema, or waiting process is stored server-side between requests.
  See `Portico.Elicitation` for key configuration and custom verification.
  Do not request secrets through form elicitation.
  """
  defstruct [:message, :schema]
  @type t :: %__MODULE__{message: String.t(), schema: map()}
  @type answer :: {:accept, map()} | :decline | :cancel

  @doc """
  Builds a form from a message and a required `schema:` option.

  A single-choice field uses `type: "string", enum: ["red", "green", "blue"]`.
  Choices must be a nonempty list of unique UTF-8 strings. An optional default
  must be one of those choices. Use `title` and `description` to label the field.
  Labeled choices use `oneOf: [%{const: "#ff0000", title: "Red"}, ...]`
  instead of `enum`. Constants must be unique strings, each with a string title;
  an optional default must match a constant, not its label.
  Multiple-choice fields use `type: "array"` with
  `items: %{type: "string", enum: ["red", "green", "blue"]}`. Optional
  `minItems` and `maxItems` limit the selection count. Defaults must be lists
  of allowed strings satisfying those limits. Labeled multiple-choice fields use
  `items: %{anyOf: [%{const: "#ff0000", title: "Red"}, ...]}`. Defaults contain
  constants, not display labels.
  Invalid declarations return `{:error, :invalid_schema}`.
  """
  @spec form(String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def form(message, options) do
    cond do
      not (is_binary(message) and String.valid?(message)) -> {:error, :invalid_message}
      not Keyword.keyword?(options) -> {:error, :invalid_options}
      Keyword.keys(options) != [:schema] -> {:error, :invalid_options}
      true -> build(message, options[:schema])
    end
  end

  defp build(message, schema) when is_map(schema) and not is_struct(schema) do
    {schema, _validator} = Portico.Schema.build!(schema, __ENV__)

    if supported_schema?(schema),
      do: {:ok, %__MODULE__{message: message, schema: schema}},
      else: {:error, :invalid_schema}
  rescue
    _ -> {:error, :invalid_schema}
  end

  defp build(_message, _schema), do: {:error, :invalid_schema}

  defp supported_schema?(schema) do
    schema["type"] == "object" and is_map(schema["properties"]) and
      Enum.all?(Map.keys(schema), &(&1 in ["type", "properties", "required"])) and
      Enum.all?(Map.get(schema, "required", []), &Map.has_key?(schema["properties"], &1)) and
      Enum.all?(schema["properties"], fn {_name, field} -> supported_field?(field) end)
  end

  defp supported_field?(%{"type" => "string", "enum" => choices} = field) do
    is_list(choices) and choices != [] and Enum.all?(choices, &is_binary/1) and
      length(Enum.uniq(choices)) == length(choices) and
      Enum.all?(Map.keys(field), &(&1 in ["type", "enum", "title", "description", "default"])) and
      (not Map.has_key?(field, "default") or field["default"] in choices)
  end

  defp supported_field?(%{"type" => "string", "oneOf" => choices} = field) do
    is_list(choices) and choices != [] and Enum.all?(choices, &titled_choice?/1) and
      Enum.all?(Map.keys(field), &(&1 in ["type", "oneOf", "title", "description", "default"])) and
      unique_constants?(choices, field)
  end

  defp supported_field?(%{"type" => "array", "items" => items} = field) do
    not is_nil(selection_values(items)) and
      Enum.all?(
        Map.keys(field),
        &(&1 in ["type", "items", "title", "description", "minItems", "maxItems", "default"])
      ) and
      (not Map.has_key?(field, "maxItems") or Map.get(field, "minItems", 0) <= field["maxItems"]) and
      (not Map.has_key?(field, "default") or valid_selection?(field["default"], field))
  end

  defp supported_field?(%{"type" => type} = field) do
    specific =
      case type do
        "string" -> ["minLength", "maxLength", "format"]
        type when type in ["number", "integer"] -> ["minimum", "maximum"]
        "boolean" -> []
        _ -> nil
      end

    not is_nil(specific) and
      Enum.all?(
        Map.keys(field),
        &(&1 in (["type", "title", "description", "default"] ++ specific))
      ) and
      (not Map.has_key?(field, "format") or
         field["format"] in ["email", "uri", "date", "date-time"])
  end

  defp supported_field?(_field), do: false

  defp selection_values(%{"type" => "string", "enum" => choices} = items)
       when map_size(items) == 2 do
    if supported_field?(items), do: choices
  end

  defp selection_values(%{"anyOf" => choices} = items) when map_size(items) == 1 do
    if is_list(choices) and choices != [] and Enum.all?(choices, &titled_choice?/1) and
         unique_constants?(choices, %{}) do
      Enum.map(choices, & &1["const"])
    end
  end

  defp selection_values(_items), do: nil

  defp valid_selection?(values, field) when is_list(values) do
    Enum.all?(values, &(&1 in selection_values(field["items"]))) and
      length(values) >= Map.get(field, "minItems", 0) and
      (not Map.has_key?(field, "maxItems") or length(values) <= field["maxItems"])
  end

  defp valid_selection?(_values, _field), do: false

  defp titled_choice?(%{"const" => value, "title" => title} = choice),
    do: map_size(choice) == 2 and is_binary(value) and is_binary(title)

  defp titled_choice?(_choice), do: false

  defp unique_constants?(choices, field) do
    values = Enum.map(choices, & &1["const"])

    length(Enum.uniq(values)) == length(values) and
      (not Map.has_key?(field, "default") or field["default"] in values)
  end
end
