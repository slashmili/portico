defmodule PorticoExample.MCP do
  use Portico.Server, name: "portico-example", version: "0.1.0"

  prompt "explain_code", PorticoExample.Prompts.ExplainCode
  prompt "review_code", PorticoExample.Prompts.ReviewCode

  tool "add", PorticoExample.Tools.Add
  tool "approve_report", PorticoExample.Tools.ApproveReport
  tool "choose_color", PorticoExample.Tools.ChooseColor
  tool "choose_colors", PorticoExample.Tools.ChooseColors
  tool "count", PorticoExample.Tools.Count
  tool "greet", PorticoExample.Tools.Greet
  tool "set_status", PorticoExample.Tools.SetStatus
  tool "summarize", PorticoExample.Tools.Summarize
  tool "summarize_text", PorticoExample.Tools.SummarizeText
  resource "company://docs", PorticoExample.Resources.Documents
  resource "company://handbook", PorticoExample.Resources.Handbook
  resource "company://reviewed-report", PorticoExample.Resources.ReviewedReport
  resource "company://sample", PorticoExample.Resources.Sample
  resource "company://status", PorticoExample.Resources.Status
  resource "company://welcome", PorticoExample.Resources.Welcome
  resource_template "company://handbook/{section}", PorticoExample.Resources.HandbookSection
  resource_template "company://policies/{name}", PorticoExample.Resources.Policy

  @impl true
  def handle_subscribe(filter, _request) do
    accepted = Enum.filter(filter.resource_subscriptions, &(&1 == "company://status"))

    if accepted != [] do
      {:ok, _} = Registry.register(PorticoExample.Events, :status, nil)
    end

    {:ok, %{resource_subscriptions: accepted}, %{}}
  end

  @impl true
  def handle_info({:status_changed, uri}, state) do
    :ok = Portico.Subscription.send({:resource_updated, uri})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
