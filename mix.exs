defmodule Argus.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/QuinnWilton/argus"

  def project do
    [
      app: :argus,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      # The test fixtures deliberately call into applications argus does not
      # depend on (they are what the analyses detect).
      xref: [exclude: [:ssl, :mnesia, :telemetry, Plug.Crypto]],
      description: "BEAM program analysis via Souffle Datalog",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "Argus",
      docs: docs(),

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
      # BEAM file analysis: disassembly and the corrected Line-chunk table
      # that line_info resolution depends on (0.2.0+).
      {:beam_spy, "~> 0.2"},

      # Dev/Test
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/dl mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
