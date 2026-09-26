defmodule PorticoExample.Prompts.ReviewCode do
  use Portico.Prompt,
    description: "Prepare a code review request.",
    arguments: [code: [description: "Code to review", required: true]]

  @impl true
  def get(%{"code" => code}, _request) do
    {:ok, prompt} = Portico.Prompt.text("Review this code for bugs:\n\n#{code}")
    {:ok, prompt}
  end
end
