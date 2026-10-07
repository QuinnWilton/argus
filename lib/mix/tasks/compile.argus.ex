defmodule Mix.Tasks.Compile.Argus do
  @shortdoc "Analyzes compiled beams with argus's Datalog analyses"

  @moduledoc """
  An analysis-only `Mix.Task.Compiler`: append it after the stock
  compilers and it reads the `.beam` files they just produced, runs the
  configured argus analyses incrementally, and reports findings as
  compiler diagnostics with pentiment-rendered frames.

      def project do
        [compilers: Mix.compilers() ++ [:argus], ...]
      end

  Because argus runs last, its `:error` status can never block another
  compiler — only the overall exit status. And because Mix halts the
  compiler chain on `:error`, argus only ever sees the ebin of a
  *successful* compile.

  Cross-VM incrementality comes from `Roux.Lang.Manifest`: extraction
  and solve memos persist per run, so a warm `mix compile` re-runs
  nothing for unchanged beams, a comment-only edit re-extracts one
  module and re-runs zero solves (the semantic-facts cutoff
  seam), and prior findings re-emit from memo hits on every run —
  including `:noop` runs, matching the Elixir compiler's
  `--all-warnings` behavior.

  Configuration lives under the `argus:` project key — see
  `Argus.Config` (a `scry:` key, or the `:scry` compiler, raises with the
  rename). A finding's severity is its analysis's unless the
  configuration overrides it; a finding at or above `fail_on` (`:error`
  by default; `:warning` for CI) fails the build, and `engine:
  :require` makes a machine that cannot build the FlowLog engines (no
  Rust) an error instead of a notice. The first run on a machine builds
  the engines its analyses need (`Argus.FlowLog.Toolchain`); `mix
  argus.flowlog build` does it ahead of time.
  """

  use Mix.Task.Compiler

  alias Argus.Mix.Diagnostics
  alias Argus.Report

  # Mix runs a non-recursive compiler once at an umbrella's root, where
  # there is no app and no ebin to read. Recursive, it runs inside each
  # child that lists it, against that child's own beams.
  @recursive true

  @sidecar "compile.argus.diagnostics"

  @impl Mix.Task.Compiler
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [force: :boolean])

    Mix.Project.get!()
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    config = Argus.Config.load()
    cwd = File.cwd!()

    result =
      Argus.Driver.run(config, force: Keyword.get(opts, :force, false))

    notices = Report.Notice.from_result(result, config, cwd)
    entries = Report.build(result.located, config, cwd)

    rendered =
      Enum.map(notices, &Diagnostics.notice/1) ++ Diagnostics.build(entries, cwd)

    Diagnostics.print(rendered)

    diagnostics = Enum.map(rendered, & &1.diagnostic)
    write_sidecar(diagnostics)

    {status(diagnostics, result, config), diagnostics}
  end

  @impl Mix.Task.Compiler
  def manifests, do: Argus.Driver.state_files()

  @impl Mix.Task.Compiler
  def clean do
    Enum.each(Argus.Driver.state_files(), &File.rm/1)
    File.rm(sidecar_file())

    # What scry kept here before the fold, which nothing reads now.
    File.rm(Path.join(Mix.Project.manifest_path(), "compile.scry"))
    File.rm(Path.join(Mix.Project.manifest_path(), "compile.scry.diagnostics"))
    File.rm_rf(Argus.Driver.cache_dir())
    :ok
  end

  @impl Mix.Task.Compiler
  def diagnostics do
    with {:ok, binary} <- File.read(sidecar_file()),
         diagnostics when is_list(diagnostics) <- safe_decode(binary) do
      diagnostics
    else
      _ -> []
    end
  end

  # ── status ───────────────────────────────────────────────────────────

  defp status(diagnostics, %Argus.Driver.Result{} = result, config) do
    threshold = rank(config.fail_on)
    failing? = Enum.any?(diagnostics, &(rank(&1.severity) <= threshold))

    cond do
      failing? -> :error
      result.changed? -> :ok
      true -> :noop
    end
  end

  defp rank(:error), do: 0
  defp rank(:warning), do: 1
  defp rank(_informational), do: 2

  # ── sidecar (backs the diagnostics/0 callback) ───────────────────────

  defp write_sidecar(diagnostics) do
    File.mkdir_p!(Mix.Project.manifest_path())
    File.write!(sidecar_file(), :erlang.term_to_binary(diagnostics))
  end

  defp safe_decode(binary) do
    :erlang.binary_to_term(binary)
  rescue
    ArgumentError -> :error
  end

  defp sidecar_file, do: Path.join(Mix.Project.manifest_path(), @sidecar)
end
