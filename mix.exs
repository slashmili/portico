defmodule Portico.MixProject do
  use Mix.Project

  def project do
    [
      app: :portico,
      version: "0.1.0",
      description:
        "An Elixir MCP server library with module-based tools, Plug integration, streaming, and form elicitation.",
      source_url: "https://github.com/slashmili/portico",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/slashmili/portico"}
      ],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 91]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.20"},
      {:plug_crypto, "~> 2.1"},
      {:jsv, "~> 0.22.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
