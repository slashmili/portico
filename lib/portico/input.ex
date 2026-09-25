defmodule Portico.Input do
  @moduledoc """
  A form requested by a tool with `{:ok, form, request_state}`.

  `form/2` validates and normalizes a flat JSON Schema with string, number,
  integer, or boolean fields. This first slice excludes enum selectors, arrays,
  nested objects, references, and URL mode. Errors return tuples.

  Portico protects the form and application state in an expiring signed token.
  Accepted answers are validated against that form before `handle_input/3` runs.
  No state, schema, or waiting process is stored server-side between requests.
  See `Portico.Elicitation` for key configuration and custom verification.
  Do not request secrets through form elicitation.
  """
  defstruct [:message, :schema]
  @type t :: %__MODULE__{message: String.t(), schema: map()}
  @type answer :: {:accept, map()} | :decline | :cancel

  @doc "Builds a form from a message and a required `schema:` option."
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
end
