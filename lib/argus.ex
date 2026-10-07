defmodule Argus do
  @moduledoc """
  BEAM program analysis via incremental Datalog (FlowLog).

  Argus extracts facts from BEAM bytecode and feeds them to Datalog rules
  for whole-program, multi-module analysis, each program compiled by
  FlowLog into a Differential Dataflow engine that keeps its results up
  to date as the facts change (`Argus.FlowLog`). The pipeline is:

      .beam files → normalize → emit facts → FlowLog engines → results

  ## Quick start

      # Find two owners of one relationship across supervisor branches.
      Argus.analyze([MyApp.Supervisor, MyApp.Worker], :coupling)

      # Find ETS tables created without heir protection.
      Argus.analyze([MyApp.Cache], :ets)

      # Run custom Datalog rules.
      Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})

      # Run every built-in analysis and get structured findings.
      Argus.run_analyses([MyApp.Supervisor, MyApp.Worker])

  ## Architecture

  Layer 1 (generic) walks every BEAM instruction and emits base facts about
  instructions, registers, control flow, and calls. Layer 2 (domain extractors)
  produces higher-level semantic facts by interpreting OTP patterns, supervision
  trees, and other BEAM-specific constructs.

  Both layers feed the engines, which evaluate Datalog rules and return
  derived relations as results.
  """

  @doc """
  Runs an analysis against the given modules.

  See `Argus.Analysis.run/3` for details.
  """
  @spec analyze([atom() | String.t()], Argus.Analysis.analysis(), keyword()) ::
          {:ok, Argus.Analysis.result()} | {:error, term()}
  defdelegate analyze(modules, analysis, opts \\ []), to: Argus.Analysis, as: :run

  @doc """
  Runs analyses and returns structured findings.

  Extracts facts from the given modules (atoms or `.beam` paths) once,
  evaluates each selected analysis against them, and converts every result
  row into a finding with severity, prose, and code anchors.

  See `Argus.Findings.run/2` for options and the degradation contract.

      {:ok, findings} = Argus.run_analyses([MyApp.Cache], analyses: [:ets])
      Enum.each(findings.findings, &IO.puts(&1.title))
  """
  @spec run_analyses([atom() | String.t()], keyword()) ::
          {:ok, Argus.Findings.t()} | {:error, term()}
  defdelegate run_analyses(modules, opts \\ []), to: Argus.Findings, as: :run
end
