defmodule Argus.MixProject do
  use Mix.Project

  @version "0.20.1"
  @source_url "https://github.com/QuinnWilton/argus"

  def project do
    [
      app: :argus_beam,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      # The fixture projects' sources live under test/projects but are
      # compiled by their own Mix projects, never loaded as tests; the
      # report's sources are text a renderer reads; the corpus pairs and
      # the pinned analysis inputs are data a test reads.
      test_ignore_filters: [
        &String.starts_with?(&1, "test/fixtures/"),
        &String.starts_with?(&1, "test/projects/"),
        &String.starts_with?(&1, "test/argus/report/sources/"),
        &(&1 in ["test/corpus/pairs.exs", "test/argus/analysis_inputs.exs"])
      ],
      deps: deps(),
      escript: escript(),
      dialyzer: dialyzer(),
      # The test fixtures deliberately call into applications argus does not
      # depend on (they are what the analyses detect).
      elixirc_options: [no_warn_undefined: [:ssl, :mnesia, :telemetry, Plug.Crypto]],
      description:
        "Whole-program BEAM analysis via Souffle Datalog: supervision, GenServer " <>
          "and OTP bug detectors over compiled beams (the Argus modules).",
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

  # The corpus tally runs where the corpus gate does: the facts cache is
  # keyed on the dependencies on the code path, so a tally in another
  # environment would extract every checkout a second time.
  def cli do
    [preferred_envs: ["argus.corpus": :test, "escript.build": :prod]]
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
      # The incremental query graph (memos, the manifest, the blob store).
      {:roux, "~> 0.2.3"},
      {:telemetry, "~> 1.0"},
      # Findings rendered as source frames.
      {:pentiment, "~> 0.2"},
      # Pentiment's lexers: syntax highlighting of the frames on a terminal.
      # Optional, because a hard dependency collides with the `only: :dev`
      # or `only: :docs` restriction most projects put on makeup through
      # ex_doc; a project that wants highlighting adds the lexers itself.
      {:makeup_elixir, "~> 1.0", optional: true},
      {:makeup_erlang, "~> 1.0", optional: true},

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

  defp elixirc_paths(:test), do: ["lib", "test/fixtures", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The race paper's examples are Erlang, and are kept in the paper's words.
  defp erlc_paths(:test), do: ["test/fixtures/erl"]
  defp erlc_paths(_), do: []

  # The `argus` escript (`Argus.CLI`): argus over a rebar3, Gleam or
  # erlang.mk project, or bare ebins, with Elixir inside it. Built in
  # :prod (`mix escript.build`), so the dev and test dependencies stay
  # out; the Datalog rules travel in its code (`Argus.Dl.Embedded`).
  defp escript do
    [main_module: Argus.CLI, name: "argus", app: nil]
  end

  # Hex knows this package as `argus_beam` (`argus` was taken; it was
  # `panoptes` until 0.20); the modules keep the `Argus` namespace.
  defp package do
    [
      name: "argus_beam",
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
      extras:
        ["README.md", "docs/bug-classes.md", "CHANGELOG.md"] ++
          Enum.map(Path.wildcard("docs/{analyses,design}/*.md"), fn path ->
            {path, filename: String.replace(Path.rootname(path), "/", "-")}
          end),
      assets: %{"images" => "images"},
      # Old entries name functions later removed or made private; they
      # render as plain code, which is right for a changelog.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
