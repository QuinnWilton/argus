defmodule Mix.Tasks.Argus do
  @shortdoc "Runs argus analyses over the compiled project (one-shot)"

  @moduledoc """
  The credo-style one-shot entry point. Compiles the project first, then
  drives the same incremental core as `mix compile.scry` against the
  same manifest — a checkout that already ran `mix compile` costs a
  validation walk, not a re-analysis.

      mix scry                      # the configured analyses
      mix scry coupling ets         # specific analyses
      mix scry security             # a named set
      mix scry --all                # every builtin analysis
      mix scry --list               # what's available
      mix scry --format json        # machine-readable findings
      mix scry --fail-above 0       # exit 1 when findings exceed the count
      mix scry --include-deps       # feed dependency beams to the call graph
      mix scry --force              # ignore the manifest, recompute everything

  A finding at or above the compiler's `fail_on` fails `mix compile`, not
  this task: it is reported here like any other, and `--fail-above` is
  the gate. A project that does not compile is an error.

  Unlike the compiler (which degrades with a notice), a missing souffle
  binary here is an error: a one-shot analysis run without a solver has
  nothing to say.

  Project configuration (`scry:` — severity overrides, ignores) applies
  to this task too; positional analyses and `--all`/`--include-deps`
  override the corresponding config keys for the run.
  """

  use Mix.Task

  alias Argus.Driver.Result

  @recursive true

  @switches [
    list: :boolean,
    all: :boolean,
    format: :string,
    fail_above: :integer,
    include_deps: :boolean,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("scry: unknown options: #{inspect(invalid)}")
    end

    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    if opts[:list] do
      list()
    else
      compile!()
      analyze(opts, positional)
    end
  end

  defp list do
    default = Argus.Graph.default_analyses()

    rows =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.reject(&(&1.name() == :coverage))
      |> Enum.sort_by(& &1.name())

    IO.puts("Available analyses (* = in the default set):\n")

    Enum.each(rows, fn mod ->
      marker = if mod.name() in default, do: "*", else: " "
      IO.puts("  #{marker} #{mod.name()} — #{mod.description()}")
    end)

    sets =
      Argus.Analysis.sets()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, members} -> "    #{name}: #{Enum.join(members, " ")}" end)

    IO.puts("\nSets (as an analysis name in config or on the command line):\n\n#{sets}")
  end

  # Without --no-prune-code-paths, a project that declares an explicit
  # `applications:` list has every dependency outside that list — scry
  # and its own deps included — pruned from the code path by the compile
  # step, and the analysis below fails to load Argus.Config.
  #
  # With --return-errors, an :error status comes back instead of exiting.
  # The compiler chain ends with scry's own compiler, whose status is
  # :error whenever a finding reaches `fail_on` — exactly the findings
  # this task exists to report, so that status must not stop it. An error
  # from any other compiler means the ebin is not the source's, and there
  # is nothing sound to analyze.
  defp compile! do
    case Mix.Task.run("compile", ["--no-prune-code-paths", "--return-errors"]) do
      {:error, diagnostics} ->
        if Enum.any?(diagnostics, &(&1.severity == :error and &1.compiler_name != "scry")) do
          Mix.raise("scry: the project does not compile; fix the errors above first")
        end

      _ok_or_noop ->
        :ok
    end
  end

  defp analyze(opts, positional) do
    config = configure(Argus.Config.load(), opts, positional)
    cwd = File.cwd!()

    result =
      Argus.Driver.run(config,
        manifest: Argus.Driver.manifest_file(),
        cache: Argus.Driver.cache_dir(),
        force: Keyword.get(opts, :force, false)
      )

    if Result.souffle_missing?(result) do
      Mix.raise(
        "scry: souffle binary not found on PATH — install souffle " <>
          "(https://souffle-lang.github.io) to run the analyses"
      )
    end

    report_degraded(Result.degraded(result))

    Enum.each(Result.extraction_errors(result), fn error ->
      Mix.shell().error("scry: " <> Argus.Mix.Diagnostics.extraction_error_message(error))
    end)

    Enum.each(Result.duplicates(result), fn %{module: module, used: used, shadowed: shadowed} ->
      Mix.shell().error(
        "scry: " <> Argus.Mix.Diagnostics.duplicate_message(module, used, shadowed)
      )
    end)

    findings_by_file = Result.findings_by_file(result)
    entries = Argus.Mix.Diagnostics.resolve(findings_by_file, config, cwd)

    case Keyword.get(opts, :format, "text") do
      "text" ->
        Argus.Report.text(Argus.Mix.Diagnostics.build(findings_by_file, config, cwd))

      "json" ->
        Argus.Report.json(entries, cwd)

      other ->
        Mix.raise("scry: unknown --format #{inspect(other)}; expected text or json")
    end

    check_fail_above(entries, Keyword.get(opts, :fail_above))
  end

  defp configure(config, opts, positional) do
    config
    |> override_analyses(opts, positional)
    |> override_include_deps(opts)
  end

  defp override_analyses(config, opts, positional) do
    cond do
      opts[:all] ->
        all =
          Argus.Analysis.builtin_analysis_modules()
          |> Enum.reject(&(&1.name() == :coverage))
          |> Enum.map(& &1.name())
          |> Enum.sort()

        %{config | analyses: all}

      positional != [] ->
        # Re-validated through Config so a typo aborts with the known list.
        names = Enum.map(positional, &String.to_atom/1)
        %{config | analyses: Argus.Config.load(analyses: names).analyses}

      true ->
        config
    end
  end

  defp override_include_deps(config, opts) do
    case Keyword.fetch(opts, :include_deps) do
      {:ok, value} -> %{config | include_deps: value}
      :error -> config
    end
  end

  defp report_degraded(degraded) do
    Enum.each(degraded, fn %{analysis: analysis, reason: reason} ->
      Mix.shell().error(
        "scry: the #{analysis} analysis degraded and reported nothing: #{inspect(reason)}"
      )
    end)
  end

  defp check_fail_above(_entries, nil), do: :ok

  defp check_fail_above(entries, threshold) do
    count = length(entries)

    if count > threshold do
      Mix.raise("scry: #{count} findings exceed --fail-above #{threshold}")
    end

    :ok
  end
end
