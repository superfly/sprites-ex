defmodule Sprites.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/superfly/sprites-ex"

  def project do
    [
      app: :sprites,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Sprites",
      description: "Elixir SDK for Sprites code container runtime",
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
      # Use the tagged Git source until :client_signals is published on Hex.
      {:client_signals,
       git: "https://github.com/superfly/client-signals", sparse: "elixir", tag: "v0.4.1"},
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
