defmodule Argus.MixProject do
  use Mix.Project

  @version "0.20.0-dev"
  @source_url "https://github.com/QuinnWilton/argus"

  def project do
    [
      app: :panoptes,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      # The test fixtures deliberately call into applications argus does not
      # depend on (they are what the analyses detect).
      xref: [exclude: [:ssl, :mnesia, :telemetry, Plug.Crypto]],
      description:
        "Whole-program BEAM analysis via Souffle Datalog: supervision, GenServer " <>
          "and OTP bug detectors over compiled beams (the Argus modules).",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "Panoptes",
      docs: docs(),

      # Test
      test_coverage: [
        summary: [threshold: 80]
      ]
    ]
  end

  # The corpus tally runs where the corpus gate does: the facts cache is
  # keyed on the dependencies on the code path, so a tally in another
  # environment would extract every checkout a second time.
  def cli do
    [preferred_envs: ["argus.corpus": :test]]
  end

  def application do
    [
      # inets, ssl and public_key: Argus.Priors.Jev's HTTP client. They are
      # OTP's own and start only when a prior is asked.
      extra_applications: [:logger, :inets, :ssl, :public_key]
    ]
  end

  defp deps do
    [
      # BEAM file analysis: disassembly and the corrected Line-chunk table
      # that line_info resolution depends on (0.2.0+).
      {:beam_spy, "~> 0.2"},

      # Dev/Test
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      # Fixtures for the GenStage-shaped rules `use GenStage`.
      {:gen_stage, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:presubmit, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  # The race paper's examples are Erlang, and are kept in the paper's words.
  defp erlc_paths(:test), do: ["test/fixtures/erl"]
  defp erlc_paths(_), do: []

  # Hex knows this package as `panoptes` (Argus Panoptes; `argus` was
  # taken); the modules keep the `Argus` namespace.
  defp package do
    [
      name: "panoptes",
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
