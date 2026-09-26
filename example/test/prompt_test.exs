defmodule PorticoExample.PromptTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  test "builds a review prompt", %{mcp: mcp} do
    {:ok, prompt} = get_prompt mcp, "review_code", %{"code" => "1 + 1"}

    assert prompt.messages == [
             %{
               role: "user",
               content: %{type: "text", text: "Review this code for bugs:\n\n1 + 1"}
             }
           ]

    assert {:error, :invalid_params} = get_prompt(mcp, "review_code", %{})
  end
end
