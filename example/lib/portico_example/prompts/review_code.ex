defmodule PorticoExample.Prompts.ReviewCode do
  use Portico.Prompt,
    description: "Prepare a code review request.",
    arguments: [code: [description: "Code to review", required: true]]

  @impl true
  def get(%{"code" => code}, _request) do
    {:ok, prompt} = Portico.Prompt.text("Review this code for bugs.")

    {:ok, prompt} =
      Portico.Prompt.text(prompt, "I'll check correctness and edge cases.", role: :assistant)

    {:ok, prompt} = Portico.Prompt.text(prompt, code)
    {:ok, prompt}
  end
end
