defmodule Portico.MixProject do
  use Mix.Project

  def project do
    [
      app: :portico,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 91]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.20"},
      {:jsv, "~> 0.22.0"}
    ]
  end
end
