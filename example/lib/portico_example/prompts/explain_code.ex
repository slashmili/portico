defmodule PorticoExample.Prompts.ExplainCode do
  use Portico.Prompt,
    description: "Prepare a code explanation with language suggestions.",
    arguments: [
      language: [description: "Programming language", required: true],
      code: [description: "Code to explain", required: true]
    ]

  @impl true
  def complete("language", prefix, _request) do
    {:ok, Enum.filter(["elixir", "erlang", "python"], &String.starts_with?(&1, prefix))}
  end

  def complete(_, _, _), do: {:ok, []}

  @impl true
  def get(%{"language" => language, "code" => code}, _request) do
    {:ok, prompt} = Portico.Prompt.text("Explain this #{language} code:\n\n#{code}")
    {:ok, prompt}
  end
end
