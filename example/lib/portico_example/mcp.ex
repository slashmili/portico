defmodule PorticoExample.MCP do
  use Portico.Server, name: "portico-example", version: "0.1.0"

  tool "add", PorticoExample.Tools.Add
  tool "approve_report", PorticoExample.Tools.ApproveReport
  tool "choose_color", PorticoExample.Tools.ChooseColor
  tool "choose_colors", PorticoExample.Tools.ChooseColors
  tool "count", PorticoExample.Tools.Count
  tool "greet", PorticoExample.Tools.Greet
  tool "summarize", PorticoExample.Tools.Summarize
  resource "company://handbook", PorticoExample.Resources.Handbook
  resource "company://sample", PorticoExample.Resources.Sample
  resource_template "company://handbook/{section}", PorticoExample.Resources.HandbookSection
end
