defmodule PorticoExample.WelcomeResourceTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  setup %{mcp: mcp} do
    %{mcp: %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}}}}}
  end

  test "reads the selected language and falls back on decline or cancel", %{mcp: mcp} do
    {:ok, _form, token} = read_resource mcp, "company://welcome"

    for {answer, expected} <- [
          {%{"action" => "accept", "content" => %{"language" => "de"}}, "Willkommen"},
          {%{"action" => "accept", "content" => %{"language" => "en"}}, "Welcome"},
          {%{"action" => "decline"}, "Welcome"},
          {%{"action" => "cancel"}, "Welcome"}
        ] do
      {:ok, content} =
        read_resource mcp, "company://welcome",
          request_state: token,
          input_responses: %{"form" => answer}

      assert content.text == expected
      assert content.uri == "company://welcome"
    end
  end
end
