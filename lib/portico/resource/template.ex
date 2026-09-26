defmodule Portico.Resource.Template do
  @moduledoc false

  # Texture validates RFC6570 syntax. Matching deliberately supports only simple,
  # whole path segments; reject other expressions rather than partially match them.
  def build(raw) when is_binary(raw) do
    with true <- String.valid?(raw),
         {:ok, parsed} <- Texture.UriTemplate.parse(raw),
         {:ok, names} <- variables(parsed.parts),
         true <- names != [] and length(names) == length(Enum.uniq(names)),
         true <- whole_segments?(parsed.parts),
         rendered = Regex.replace(~r/\{[^}]+\}/, raw, "portico-variable"),
         true <- Portico.Resource.valid_uri?(rendered),
         %URI{query: nil, fragment: nil} <- URI.parse(rendered),
         prefix = raw |> String.split("{", parts: 2) |> hd(),
         %URI{path: path} when is_binary(path) <- URI.parse(prefix) do
      pattern =
        Enum.map_join(parsed.parts, fn
          {:lit, text} -> Regex.escape(text)
          {:expr, :default, [_]} -> "((?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})*)"
          :eos -> ""
        end)

      {:ok,
       %{
         regex: Regex.compile!("\\A" <> pattern <> "\\z"),
         names: names,
         shape: Regex.replace(~r/\{[^}]+\}/, raw, "{}")
       }}
    else
      _ -> {:error, :unsupported_uri_template}
    end
  rescue
    _ -> {:error, :unsupported_uri_template}
  end

  def build(_), do: {:error, :unsupported_uri_template}

  def match(template, uri) do
    case Regex.run(template.regex, uri, capture: :all_but_first) do
      nil ->
        :nomatch

      values ->
        values = Enum.map(values, &URI.decode/1)

        if Enum.all?(values, &String.valid?/1),
          do: {:ok, Map.new(Enum.zip(template.names, values))},
          else: :nomatch
    end
  end

  defp variables(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      {:expr, :default, [{:var, name, nil}]}, {:ok, names} -> {:cont, {:ok, names ++ [name]}}
      {:lit, _}, acc -> {:cont, acc}
      :eos, acc -> {:cont, acc}
      _, _ -> {:halt, :error}
    end)
  end

  defp whole_segments?(parts) do
    parts
    |> Enum.with_index()
    |> Enum.all?(fn
      {{:expr, _, _}, index} ->
        case {Enum.at(parts, index - 1), Enum.at(parts, index + 1)} do
          {{:lit, before}, {:lit, after_part}} ->
            String.ends_with?(before, "/") and String.starts_with?(after_part, "/")

          {{:lit, before}, :eos} ->
            String.ends_with?(before, "/")

          _ ->
            false
        end

      _ ->
        true
    end)
  end
end
