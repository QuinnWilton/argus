defmodule Argus.Report.Notice do
  @moduledoc """
  What a reader of the findings should know about the run itself, in one
  wording for every frontend: the Mix compiler shows a notice as a
  diagnostic of the project, `mix argus` and the escript print it on
  stderr before the findings (`Argus.Report.Text`), and the rebar3 plugin
  relays the escript.

  The kinds:

    * `:engine_unavailable` — this machine cannot build or run the
      FlowLog engines (no Rust, or one too old), so nothing was solved;
    * `:degraded` — an analysis failed and reported nothing (its engine
      failed or timed out, a stage it reads failed, its rules and argus's
      code are out of step);
    * `:extraction_error` — a step of extraction failed on a module, and
      the analyses ran without those facts;
    * `:duplicate` — a module more than one ebin defines, and which beam
      was analyzed;
    * `:points_to_bounded` — the process points-to stage outgrew its
      budget and ran bounded;
    * `:points_to_coarse` — it outgrew the budget bounded too, and ran
      coarse;
    * `:stale` — sources newer than their beams (the escript, which
      never builds): the findings are about the code as last built;
    * `:unused_ignore` — an `ignore: [findings: ...]` entry that left
      nothing out: the finding it was written for is gone, or it names
      another place than the one the finding is reported in.
  """

  alias Argus.Driver.Result

  @enforce_keys [:kind, :severity, :message]
  defstruct @enforce_keys

  @type kind ::
          :engine_unavailable
          | :degraded
          | :extraction_error
          | :duplicate
          | :points_to_bounded
          | :points_to_coarse
          | :stale
          | :unused_ignore

  @type t :: %__MODULE__{
          kind: kind(),
          severity: Argus.Findings.severity(),
          message: String.t()
        }

  @doc """
  The notices of a driver run: its own (`Argus.Driver.Result` notices),
  one for each analysis that degraded, and one for each `ignore:
  [findings: ...]` entry that left out none of its analysis's findings,
  in that order. An entry whose analysis did not report (not run, or
  degraded) is not judged. `config`
  decides how loud a machine without the engines is (`engine: :warn`
  makes it an `:info`, `:require` an `:error`); `cwd` is what the paths
  in a duplicate's notice are relative to.
  """
  @spec from_result(Result.t(), Argus.Config.t(), String.t()) :: [t()]
  def from_result(%Result{} = result, %Argus.Config{} = config, cwd) do
    {unavailable, rest} = Enum.split_with(result.notices, &(&1 == :engine_unavailable))

    Enum.map(unavailable, fn :engine_unavailable -> engine_unavailable(config.engine) end) ++
      Enum.map(Result.degraded(result), &degraded/1) ++
      Enum.map(rest, &of(&1, cwd)) ++
      Enum.map(unused_ignores(result, config), &unused_ignore(config, &1))
  end

  defp unused_ignores(result, config) do
    for %{analyses: analyses} = ignored <- config.ignore_findings,
        reported <- [for({:ok, located} <- Enum.map(analyses, &result.located[&1]), do: located)],
        reported != [],
        not Enum.any?(List.flatten(reported), &Argus.Config.ignore_matches?(ignored, &1.finding)),
        do: ignored
  end

  defp of({:extraction_error, error}, _cwd), do: extraction_error(error)
  defp of({:duplicate, duplicate}, cwd), do: duplicate(duplicate, cwd)
  defp of({:points_to_bounded, leaves}, _cwd), do: points_to_bounded(leaves)
  defp of({:points_to_coarse, leaves}, _cwd), do: points_to_coarse(leaves)

  @doc """
  The engines cannot be built here (`Argus.FlowLog.Toolchain`). Under
  `engine: :warn` (the default) the run goes on without the Datalog
  analyses; under `:require` it fails. The message says what is missing
  and how to install it.
  """
  @spec engine_unavailable(:warn | :require) :: t()
  def engine_unavailable(:warn) do
    notice(
      :engine_unavailable,
      :info,
      "Datalog analyses skipped: " <>
        Argus.FlowLog.not_found_message() <>
        " Set engine: :require in argus's configuration to make this an error."
    )
  end

  def engine_unavailable(:require) do
    notice(
      :engine_unavailable,
      :error,
      "argus is configured with engine: :require, and cannot run its analyses: " <>
        Argus.FlowLog.not_found_message()
    )
  end

  @doc "An analysis that failed and reported nothing."
  @spec degraded(%{analysis: atom(), reason: term()}) :: t()
  def degraded(%{analysis: analysis, reason: reason}) do
    notice(
      :degraded,
      :warning,
      "the #{analysis} analysis degraded and reported nothing: " <> describe(reason)
    )
  end

  @doc """
  What extraction could not do on a module: the analyses ran on partial
  facts, so a finding that needed the rest may be missing. Distinct from
  an analysis that degraded, which reported nothing.
  """
  @spec extraction_error(Result.extraction_error()) :: t()
  def extraction_error(%{name: name, step: "module", reason: reason}) do
    notice(
      :extraction_error,
      :warning,
      "#{name} could not be extracted (#{reason}); the analyses ran without its facts, " <>
        "so findings that involve it may be missing"
    )
  end

  def extraction_error(%{name: name, step: "pipeline", reason: reason}) do
    notice(
      :extraction_error,
      :warning,
      "#{name} lost all its facts in extraction (#{reason}); the analyses ran without them, " <>
        "so findings that involve it may be missing — the next run extracts it again"
    )
  end

  def extraction_error(%{name: name, step: step, reason: reason}) do
    notice(
      :extraction_error,
      :warning,
      "#{name}: the #{step} extraction step failed (#{reason}); the analyses ran on the rest " <>
        "of its facts, so findings that needed that step's may be missing"
    )
  end

  @doc """
  A module more than one scanned ebin defines (`include_deps`): which
  beam is analyzed, and which are not.
  """
  @spec duplicate(Result.duplicate(), String.t()) :: t()
  def duplicate(%{module: module, used: used, shadowed: shadowed}, cwd) do
    notice(
      :duplicate,
      :warning,
      "#{inspect(module)} is defined in more than one ebin; analyzing " <>
        "#{Argus.Report.relative(used, cwd)} and not " <>
        Enum.map_join(shadowed, ", ", &Argus.Report.relative(&1, cwd))
    )
  end

  @doc """
  The process points-to stage outgrew its budget and ran bounded: the
  leaves it resolved coarsely have a sound superset of their exact rows,
  so a finding about one of them may be a false alarm.
  """
  @spec points_to_bounded([String.t()]) :: t()
  def points_to_bounded(leaves) do
    count = length(leaves)

    notice(
      :points_to_bounded,
      :info,
      "the process points-to stage outgrew its budget and ran bounded: " <>
        "#{count} pervasive #{if count == 1, do: "term was", else: "terms were"} resolved " <>
        "coarsely, so findings about the processes #{if count == 1, do: "it holds", else: "they hold"} " <>
        "may include some that cannot happen"
    )
  end

  @doc """
  The process points-to stage outgrew its budget bounded too and ran
  coarse: every leaf resolved coarsely, so a finding about any process
  may be a false alarm.
  """
  @spec points_to_coarse([String.t()]) :: t()
  def points_to_coarse(leaves) do
    notice(
      :points_to_coarse,
      :info,
      "the process points-to stage outgrew its budget, bounded too, and ran coarse: " <>
        "every term holding a process (#{length(leaves)}) was resolved coarsely, so " <>
        "findings about any process may include some that cannot happen"
    )
  end

  @doc """
  An `ignore: [findings: ...]` entry that left nothing out: no finding
  of its analysis is reported in the module or function it names.
  """
  @spec unused_ignore(Argus.Config.t(), Argus.Config.ignored_finding()) :: t()
  def unused_ignore(%Argus.Config{} = config, %{entry: {analysis, _} = entry}) do
    ctx = Argus.ConfigError.context(config.origin)

    notice(
      :unused_ignore,
      :warning,
      "ignore findings entry #{Argus.ConfigError.show(ctx, entry)} left nothing out: no " <>
        "#{analysis} finding is reported there now. Remove it, or name the module or " <>
        "function the finding is reported in, which its help shows"
    )
  end

  @doc """
  Sources newer than their beams, or without one (`Argus.Project.stale/1`):
  the findings are about the code as last built, and `build` builds it.
  """
  @spec stale([Path.t()], String.t() | nil) :: t()
  def stale(sources, build) do
    count = length(sources)
    {shown, rest} = Enum.split(sources, 3)
    listed = Enum.join(shown, ", ") <> if(rest == [], do: "", else: ", and #{length(rest)} more")

    notice(
      :stale,
      :warning,
      "#{count} #{if count == 1, do: "source is", else: "sources are"} newer than " <>
        "#{if count == 1, do: "its beam", else: "their beams"} (#{listed}): the findings are " <>
        "about the code as last built" <> if(build, do: "; run `#{build}` first", else: "")
    )
  end

  defp notice(kind, severity, message),
    do: %__MODULE__{kind: kind, severity: severity, message: message}

  defp describe({:points_to, reason}), do: "its points-to stage failed: " <> describe(reason)
  defp describe(reason), do: Argus.FlowLog.describe_error(reason)
end
