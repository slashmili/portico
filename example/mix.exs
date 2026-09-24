defmodule PorticoExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :portico_example,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:portico, path: ".."}, {:bandit, "~> 1.12"}]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {PorticoExample.Application, []}]
  end
end
