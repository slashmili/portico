defmodule PorticoExample.Tools.Add do
  use Portico.Tool,
    description: "Add two integers.",
    input_schema: %{
      type: "object",
      properties: %{a: %{type: "integer"}, b: %{type: "integer"}},
      required: ["a", "b"],
      additionalProperties: false
    }

  @impl true
  def call(%{"a" => a, "b" => b} = arguments, _request)
      when is_integer(a) and is_integer(b) and map_size(arguments) == 2 do
    {:ok, Portico.Result.text(Integer.to_string(a + b))}
  end

  def call(_arguments, _request) do
    result =
      %Portico.Result{}
      |> Portico.Result.text("Provide exactly two integers, a and b.")
      |> Portico.Result.text("Example: a=2, b=3.")
      |> Portico.Result.put_error(true)

    {:ok, result}
  end
end
