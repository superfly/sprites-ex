defmodule SpritesTestCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprites_test_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:sprites, path: ".."},
      {:jason, "~> 1.4"}
    ]
  end

  defp escript do
    [
      main_module: SpritesTestCli,
      name: "test-cli",
      path: "test-cli"
    ]
  end
end
