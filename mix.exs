defmodule Argus.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :argus,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # Test
      test_coverage: [
        summary: [threshold: 80]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # BEAM file analysis (workspace sibling).
      {:beam_spy, path: "../beam_spy"},

      # Dev/Test
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end
end
