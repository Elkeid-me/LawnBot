defmodule LawnBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :lawn_bot,
      version: "0.2.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "LawnBot",
      source_url: "https://github.com/Elkeid-me/LawnBot",
      homepage_url: "http://elkeid-me.github.io/LawnBot",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      included_applications: [:mnesia],
      mod: {LawnBot.Application, []}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.7.5"},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:websockex, "~> 0.5.1"}
    ]
  end

  defp docs do
    [
      extras: ["README.md"],
      logo: "assets/ex_doc_logo.png"
    ]
  end
end
