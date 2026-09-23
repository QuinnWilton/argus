defmodule Mix.Tasks.Compile.Scry do
  @shortdoc "Analyzes compiled beams with argus's Datalog analyses"

  @moduledoc """
  An analysis-only `Mix.Task.Compiler`: append it after the stock
  compilers and it reads the `.beam` files they just produced, runs the
  configured argus analyses incrementally, and reports findings as
  compiler diagnostics with pentiment-rendered frames.

      def project do
        [compilers: Mix.compilers() ++ [:scry], ...]
      end

  Because scry runs last, its `:error` status can never block another
  compiler — only the overall exit status. And because Mix halts the
  compiler chain on `:error`, scry only ever sees the ebin of a
  *successful* compile.

  Cross-VM incrementality comes from `Roux.Lang.Manifest`: extraction
  and solve memos persist per run, so a warm `mix compile` re-runs
  nothing for unchanged beams, a comment-only edit re-extracts one
  module and re-runs zero Souffle solves (the semantic-facts cutoff
  seam), and prior findings re-emit from memo hits on every run —
  including `:noop` runs, matching the Elixir compiler's
  `--all-warnings` behavior.

  Configuration lives under the `scry:` project key — see `Scry.Config`.
  Status: findings are warnings by default and never fail the build;
  `fail_on: :warning` promotes any finding to a build failure (CI), and
  `souffle: :require` makes a missing solver an error instead of a
  notice.
  """

  use Mix.Task.Compiler

  # Mix runs a non-recursive compiler once at an umbrella's root, where
  # there is no app and no ebin to read. Recursive, it runs inside each
  # child that lists it, against that child's own beams.
  @recursive true

  @sidecar "compile.scry.diagnostics"

  @impl Mix.Task.Compiler
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [force: :boolean])

    Mix.Project.get!()
    {:ok, _apps} = Application.ensure_all_started(:telemetry)

    config = Scry.Config.load()
    cwd = File.cwd!()

    result =
      Scry.Runner.run(config,
        manifest: manifest_file(),
        force: Keyword.get(opts, :force, false)
      )

    rendered =
      infrastructure(result, config) ++
        Scry.Diagnostics.build(result.findings_by_file, config, cwd)

    Scry.Diagnostics.print(rendered)

    diagnostics = Enum.map(rendered, & &1.diagnostic)
    write_sidecar(diagnostics)

    {status(diagnostics, result, config), diagnostics}
  end

  @impl Mix.Task.Compiler
  def manifests, do: [manifest_file()]

  @impl Mix.Task.Compiler
  def clean do
    File.rm(manifest_file())
    File.rm(sidecar_file())
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

  # ── infrastructure diagnostics ───────────────────────────────────────

  defp infrastructure(result, config) do
    souffle =
      case {result.souffle_missing?, config.souffle} do
        {false, _} ->
          []

        {true, :warn} ->
          [
            Scry.Diagnostics.infrastructure(
              :info,
              "souffle binary not found on PATH; Datalog analyses skipped. " <>
                "Install souffle (https://souffle-lang.github.io), or set " <>
                "scry: [souffle: :require] to make this an error."
            )
          ]

        {true, :require} ->
          [
            Scry.Diagnostics.infrastructure(
              :error,
              "souffle binary not found on PATH and scry is configured with " <>
                "souffle: :require. Install souffle " <>
                "(https://souffle-lang.github.io) to run the analyses."
            )
          ]
      end

    degraded =
      for %{analysis: analysis, reason: reason} <- result.degraded do
        Scry.Diagnostics.infrastructure(
          :warning,
          "the #{analysis} analysis degraded and reported nothing: #{inspect(reason)}"
        )
      end

    souffle ++ degraded
  end

  # ── status ───────────────────────────────────────────────────────────

  defp status(diagnostics, result, config) do
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

  defp manifest_file, do: Scry.Runner.manifest_file()
  defp sidecar_file, do: Path.join(Mix.Project.manifest_path(), @sidecar)
end
