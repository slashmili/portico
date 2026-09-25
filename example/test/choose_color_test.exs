defmodule PorticoExample.ChooseColorTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  setup %{mcp: mcp} do
    %{mcp: %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}}}}}
  end

  test "advertises choices and accepts each allowed color", %{mcp: mcp} do
    {:ok, form, state} = call_tool mcp, "choose_color", %{}
    assert form.schema["properties"]["color"]["enum"] == ["red", "green", "blue"]

    for color <- ["red", "green", "blue"] do
      {:ok, result} =
        call_tool mcp, "choose_color", %{},
          request_state: state,
          input_responses: %{"form" => %{"action" => "accept", "content" => %{"color" => color}}}

      assert_text result, "You chose #{color}."
    end
  end

  test "unknown colors cause the form to be requested again", %{mcp: mcp} do
    {:ok, form, state} = call_tool mcp, "choose_color", %{}

    for content <- [%{}, %{"color" => "purple"}, %{"color" => 1}] do
      assert {:ok, ^form, _state} =
               call_tool(mcp, "choose_color", %{},
                 request_state: state,
                 input_responses: %{"form" => %{"action" => "accept", "content" => content}}
               )
    end
  end

  test "handles decline and cancel", %{mcp: mcp} do
    {:ok, _form, state} = call_tool mcp, "choose_color", %{}

    for {action, text} <- [{"decline", "No color selected."}, {"cancel", "Cancelled."}] do
      {:ok, result} =
        call_tool mcp, "choose_color", %{},
          request_state: state,
          input_responses: %{"form" => %{"action" => action}}

      assert_text result, text
      assert result.is_error == (action == "decline")
    end
  end
end
