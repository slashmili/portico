defmodule PorticoExample.Tools.ApproveReport do
  alias PorticoExample.ReportApprovals

  use Portico.Tool,
    description: "Review and approve a sample report in the browser. Requires demo Basic auth.",
    input_schema: %{type: "object", additionalProperties: false}

  @impl true
  def call(_arguments, request) do
    case request.assigns[:demo_user] do
      nil ->
        {:ok, result} =
          Portico.Result.error("Use demo Basic auth: alice / alice-demo or bob / bob-demo.")

        {:ok, result}

      user ->
        with {:ok, id} <- ReportApprovals.create(user), do: ask(id)
    end
  end

  @impl true
  def handle_input(action, id, request) do
    # The browser and MCP request must authenticate as the same demo user.
    with {:ok, entry} <- ReportApprovals.get(id, request.assigns[:demo_user]) do
      case action do
        :accept ->
          case entry.status do
            :approved ->
              {:ok, result} = Portico.Result.text("Demo report approved.")
              {:ok, result}

            :rejected ->
              {:ok, content} = Portico.Result.error("Report approval rejected.")
              {:ok, content}

            :pending ->
              ask(id)
          end

        action when action in [:decline, :cancel] ->
          {:ok, result} =
            Portico.Result.error(
              if(action == :decline,
                do: "Report approval declined.",
                else: "Report approval cancelled."
              )
            )

          {:ok, result}
      end
    end
  end

  defp ask(id) do
    base = Application.fetch_env!(:portico_example, :public_url)

    {:ok, input} =
      Portico.Input.url("Review the sample report in your browser and approve it.",
        url: base <> "/report-approvals/" <> id
      )

    {:ok, input, id}
  end
end
