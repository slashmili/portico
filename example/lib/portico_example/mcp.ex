defmodule PorticoExample.MCP do
  use Portico.Server, name: "portico-example", version: "0.1.0"

  prompt "review_code", PorticoExample.Prompts.ReviewCode

  tool "add", PorticoExample.Tools.Add
  tool "approve_report", PorticoExample.Tools.ApproveReport
  tool "choose_color", PorticoExample.Tools.ChooseColor
  tool "choose_colors", PorticoExample.Tools.ChooseColors
  tool "count", PorticoExample.Tools.Count
  tool "greet", PorticoExample.Tools.Greet
  tool "summarize", PorticoExample.Tools.Summarize
  resource "company://docs", PorticoExample.Resources.Documents
  resource "company://handbook", PorticoExample.Resources.Handbook
  resource "company://reviewed-report", PorticoExample.Resources.ReviewedReport
  resource "company://sample", PorticoExample.Resources.Sample
  resource "company://welcome", PorticoExample.Resources.Welcome
  resource_template "company://handbook/{section}", PorticoExample.Resources.HandbookSection
  resource_template "company://policies/{name}", PorticoExample.Resources.Policy
end
