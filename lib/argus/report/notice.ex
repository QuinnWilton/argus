defmodule Argus.Report.Notice do
  @moduledoc """
  What a reader of the findings should know about the run itself, in one
  wording for every frontend: the Mix compiler shows a notice as a
  diagnostic of the project, `mix argus` and the escript print it on
  stderr before the findings (`Argus.Report.Text`), and the rebar3 plugin
  relays the escript.

  The kinds:

    * `:souffle_missing` — no solver on `PATH`, so nothing was solved;
    * `:degraded` — an analysis failed and reported nothing (its solver
      failed or timed out, a stage it reads failed, its rules and argus's
      code are out of step);
    * `:extraction_error` — a step of extraction failed on a module, and
      the analyses ran without those facts;
    * `:duplicate` — a module more than one ebin defines, and which beam
      was analyzed;
    * `:points_to_bounded` — the process points-to stage outgrew its
      budget and ran bounded;
    * `:config_renamed` — configuration under scry's name, which argus
      does not read (`Argus.ConfigError` raises with this wording);
    * `:stale` — sources newer than their beams (the escript, which
      never builds): the findings are about the code as last built.
  """

  alias Argus.Driver.Result

  @enforce_keys [:kind, :severity, :message]
  defstruct @enforce_keys

  @type kind ::
          :souffle_missing
          | :degraded
          | :extraction_error
          | :duplicate
          | :points_to_bounded
          | :config_renamed
          | :stale

  @type t :: %__MODULE__{
          kind: kind(),
          severity: Argus.Findings.severity(),
          message: String.t()
        }

  @souffle_url "https://souffle-lang.github.io"

  @doc """
  The notices of a driver run: its own (`Argus.Driver.Result` notices)
  and one for each analysis that degraded, in that order. `config`
  decides how loud a missing solver is (`souffle: :warn` makes it an
  `:info`, `:require` an `:error`); `cwd` is what the paths in a
  duplicate's notice are relative to.
  """
  @spec from_result(Result.t(), Argus.Config.t(), String.t()) :: [t()]
  def from_result(%Result{} = result, %Argus.Config{} = config, cwd) do
    {souffle, rest} = Enum.split_with(result.notices, &(&1 == :souffle_missing))

    Enum.map(souffle, fn :souffle_missing -> souffle_missing(config.souffle) end) ++
      Enum.map(Result.degraded(result), &degraded/1) ++
      Enum.map(rest, &of(&1, cwd))
  end

  defp of({:extraction_error, error}, _cwd), do: extraction_error(error)
  defp of({:duplicate, duplicate}, cwd), do: duplicate(duplicate, cwd)
  defp of({:points_to_bounded, leaves}, _cwd), do: points_to_bounded(leaves)

  @doc """
  No solver on `PATH`. Under `souffle: :warn` (the default) the run
  goes on without the Datalog analyses; under `:require` it fails.
  """
  @spec souffle_missing(:warn | :require) :: t()
  def souffle_missing(:warn) do
    notice(
      :souffle_missing,
      :info,
      "souffle binary not found on PATH; Datalog analyses skipped. " <>
        "Install souffle (#{@souffle_url}), or set souffle: :require " <>
        "in argus's configuration to make this an error."
    )
  end

  def souffle_missing(:require) do
    notice(
      :souffle_missing,
      :error,
      "souffle binary not found on PATH, and argus is configured with " <>
        "souffle: :require. Install souffle (#{@souffle_url}) to run the analyses."
    )
  end

  @doc "An analysis that failed and reported nothing."
  @spec degraded(%{analysis: atom(), reason: term()}) :: t()
  def degraded(%{analysis: analysis, reason: reason}) do
    notice(
      :degraded,
      :warning,
      "the #{analysis} analysis degraded and reported nothing: #{inspect(reason)}"
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
  Configuration under scry's name (`key`, spelled as its source spells
  it) that argus does not read: the argus name to move it to.

      iex> Argus.Report.Notice.config_renamed("scry:", "argus:").message
      "scry has moved into argus: rename scry: to argus: (the configuration is otherwise the same)"
  """
  @spec config_renamed(String.t(), String.t()) :: t()
  def config_renamed(key, renamed) do
    notice(
      :config_renamed,
      :error,
      "scry has moved into argus: rename #{key} to #{renamed} " <>
        "(the configuration is otherwise the same)"
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
end
