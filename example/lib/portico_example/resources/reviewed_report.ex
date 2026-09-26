defmodule PorticoExample.Resources.ReviewedReport do
  alias PorticoExample.ReportApprovals

  use Portico.Resource,
    name: "reviewed-report",
    description: "Read a sample report after browser approval. Requires demo Basic auth.",
    mime_type: "text/plain"

  @impl true
  def read(request) do
    case request.assigns[:demo_user] do
      nil ->
        {:ok, content} =
          Portico.Resource.text("Use demo Basic auth: alice / alice-demo or bob / bob-demo.")

        {:ok, content}

      user ->
        with {:ok, id} <- ReportApprovals.create(user), do: ask(id)
    end
  end

  @impl true
  def handle_input(action, id, request) do
    # Consent in the MCP client is not evidence of browser completion.
    with {:ok, entry} <- ReportApprovals.get(id, request.assigns[:demo_user]) do
      case action do
        :accept ->
          if entry.complete do
            {:ok, content} =
              Portico.Resource.text("Reviewed sample report: 3 orders, total 42 EUR.")

            {:ok, content}
          else
            ask(id)
          end

        action when action in [:decline, :cancel] ->
          {:ok, content} =
            Portico.Resource.text(
              if(action == :decline,
                do: "Report approval declined.",
                else: "Report approval cancelled."
              )
            )

          {:ok, content}
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
