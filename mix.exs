defmodule Sprites.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/superfly/sprites-ex"

  def project do
    [
      app: :sprites,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Sprites",
      description:
        "Elixir SDK for Fly.io Sprites: computers for agents. Manage Sprites and run remote commands from Elixir, with APIs that match the language's conventions.",
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :inets]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:gun, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:client_signals, "~> 0.4.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
