defmodule PorticoExample.ChooseColorsTest do
  use Portico.Test, server: PorticoExample.MCP, async: true

  setup %{mcp: mcp} do
    %{mcp: %{mcp | client_capabilities: %{"elicitation" => %{"form" => %{}}}}}
  end

  test "one or two selections preserve the client's order", %{mcp: mcp} do
    {:ok, form, state} = call_tool mcp, "choose_colors", %{}
    assert form.schema["properties"]["colors"]["minItems"] == 1
    assert form.schema["properties"]["colors"]["maxItems"] == 2

    assert form.schema["properties"]["colors"]["items"]["anyOf"] == [
             %{"const" => "#ff0000", "title" => "Red"},
             %{"const" => "#00ff00", "title" => "Green"},
             %{"const" => "#0000ff", "title" => "Blue"}
           ]

    for colors <- [["#ff0000"], ["#ff0000", "#0000ff"], ["#0000ff", "#00ff00"]] do
      {:ok, result} =
        call_tool mcp, "choose_colors", %{},
          request_state: state,
          input_responses: %{
            "form" => %{"action" => "accept", "content" => %{"colors" => colors}}
          }

      assert_text result, "You chose #{Enum.join(colors, ", ")}."
    end
  end

  test "invalid selections reissue the form", %{mcp: mcp} do
    {:ok, form, state} = call_tool mcp, "choose_colors", %{}

    for content <- [
          %{},
          %{"colors" => []},
          %{"colors" => ["purple"]},
          %{"colors" => ["#ff0000", "#00ff00", "#0000ff"]},
          %{"colors" => ["Red", "Blue"]},
          %{"colors" => "red"}
        ] do
      assert {:ok, ^form, _} =
               call_tool(mcp, "choose_colors", %{},
                 request_state: state,
                 input_responses: %{"form" => %{"action" => "accept", "content" => content}}
               )
    end

    for colors <- [[1], [["red"]], [%{"color" => "red"}]] do
      assert {:error, :invalid_params} =
               call_tool(mcp, "choose_colors", %{},
                 request_state: state,
                 input_responses: %{
                   "form" => %{"action" => "accept", "content" => %{"colors" => colors}}
                 }
               )
    end
  end

  test "decline and cancel finish without selections", %{mcp: mcp} do
    {:ok, _, state} = call_tool mcp, "choose_colors", %{}

    for {action, text} <- [{"decline", "No colors selected."}, {"cancel", "Cancelled."}] do
      {:ok, result} =
        call_tool mcp, "choose_colors", %{},
          request_state: state,
          input_responses: %{"form" => %{"action" => action}}

      assert_text result, text
      assert result.is_error == (action == "decline")
    end
  end
end
