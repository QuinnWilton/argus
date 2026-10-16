defmodule Mix.Tasks.Argus do
  @shortdoc "Runs argus analyses over the compiled project (one-shot)"

  @moduledoc """
  The credo-style one-shot entry point. Compiles the project first, then
  drives the same incremental core as `mix compile.argus` against the
  same manifest — a checkout that already ran `mix compile` costs a
  validation walk, not a re-analysis.

      mix argus                      # the configured analyses
      mix argus coupling ets         # specific analyses
      mix argus security             # a named set
      mix argus --all                # every builtin analysis
      mix argus --list               # what's available
      mix argus --format json        # machine-readable findings
      mix argus --fail-above 0       # fail when findings exceed the count
      mix argus --fail-on warning    # fail on a warning or an error
      mix argus --include-deps       # feed dependency beams to the call graph
      mix argus --force              # ignore the manifest, recompute everything
      mix argus --offline            # make no network call (`Argus.Offline`)
      mix argus --color always       # color the frames even into a pipe

  The command line is the `argus` escript's (`Argus.CLI.Options`), less
  what Mix decides (the project, its ebins, its state), and the report is
  the escript's, byte for byte.

  A finding at or above the compiler's `fail_on` fails `mix compile`, not
  this task: it is reported here like any other, and `--fail-above` and
  `--fail-on` are the gates. A project that does not compile is an
  error, and so is a machine that cannot build the FlowLog engines (no
  Rust): a one-shot run without them has nothing to say (the compiler
  degrades with a notice instead).

  Project configuration (`argus:` — severity overrides, ignores)
  applies to this task too; positional analyses and
  `--all`/`--include-deps` override the corresponding keys for the run.
  """

  use Mix.Task

  alias Argus.CLI.Options

  @recursive true

  @impl Mix.Task
  def run(args) do
    options =
      case Options.parse(args, :mix) do
        {:ok, options} -> options
        {:error, message} -> Mix.raise("argus: " <> message)
      end

    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    if options.offline, do: Argus.Offline.enable()

    case options.command do
      :help ->
        Mix.shell().info(@moduledoc)

      :list ->
        IO.write(Argus.CLI.list())

      :analyze ->
        Argus.Project.Mix.compile!()
        analyze(options)
    end
  end

  defp analyze(options) do
    config = Argus.CLI.override(Argus.Config.load(), options)
    cwd = File.cwd!()

    result =
      Argus.Driver.run(config, force: options.force)

    if Argus.Driver.Result.engine_unavailable?(result) do
      Mix.raise("argus: " <> Argus.FlowLog.not_found_message())
    end

    notices = Argus.Report.Notice.from_result(result, config, cwd)
    # An umbrella child's report, under its `==> app` header; JSON stays JSON.
    if options.format == :text, do: Mix.shell().print_app()
    %{entries: entries} = Argus.CLI.report(result, notices, config, options, cwd, cwd)

    if options.fail_above && length(entries) > options.fail_above do
      Mix.raise("argus: #{length(entries)} findings exceed --fail-above #{options.fail_above}")
    end

    case Argus.CLI.failing(entries, options.fail_on) do
      [] ->
        :ok

      failing ->
        Mix.raise("argus: #{length(failing)} findings at --fail-on #{options.fail_on} or above")
    end

    :ok
  end
end
