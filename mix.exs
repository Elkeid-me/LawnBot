defmodule LawnBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :lawn_bot,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "LawnBot",
      source_url: "https://github.com/Elkeid-me/LawnBot",
      homepage_url: "http://elkeid-me.github.io/LawnBot",
      docs: [
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LawnBot.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:req, "~> 0.7.5"},
      {:websockex, "~> 0.5.1"}
    ]
  end
end
