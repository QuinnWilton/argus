defmodule Argus.Driver.Result do
  @moduledoc """
  What one run of the driver found, for a frontend to render.

    * `located` — each analysis run: its findings placed in the source
      (`Argus.Located`), or why it degraded and reported nothing (the
      solver failed or timed out, a stage it reads failed, its rules
      and argus's code are out of step). An analysis the run did not
      solve (no solver, `souffle: :warn`) is not there.
    * `notices` — what a reader of the findings should know about the
      run that is not a finding (`t:notice/0`). An analysis that
      degraded is not among them: `located` says so.
    * `changed?` — whether the run found anything moved since the last
      (a Mix compiler's `:ok` against `:noop`).

  ## Notices

    * `:souffle_missing` — no solver on `PATH`: nothing was solved.
    * `{:extraction_error, error}` — a step of extraction failed on a
      module (`step: "module"` when the module could not be extracted at
      all): the analyses ran without those facts, and a finding that
      needed them may be missing.
    * `{:duplicate, duplicate}` — a module more than one scanned ebin
      defines: which beam is analyzed, and which are passed over.
    * `{:points_to_bounded, leaves}` — the process points-to stage
      outgrew its budget and ran bounded, resolving `leaves` coarsely
      (a sound superset of their exact rows).
  """

  alias Argus.Locate.Source

  @enforce_keys [:located, :notices, :changed?]
  defstruct [:located, :notices, :changed?]

  @typedoc "A module extraction could not fully read."
  @type extraction_error :: %{
          module: module() | nil,
          name: String.t(),
          step: String.t(),
          reason: String.t()
        }

  @typedoc "A module more than one scanned ebin defines."
  @type duplicate :: %{module: module(), used: String.t(), shadowed: [String.t()]}

  @type notice ::
          :souffle_missing
          | {:extraction_error, extraction_error()}
          | {:duplicate, duplicate()}
          | {:points_to_bounded, [String.t()]}

  @type t :: %__MODULE__{
          located: %{optional(atom()) => {:ok, [Argus.Located.t()]} | {:error, term()}},
          notices: [notice()],
          changed?: boolean()
        }

  @doc "The analyses that degraded, with why."
  @spec degraded(t()) :: [%{analysis: atom(), reason: term()}]
  def degraded(%__MODULE__{located: located}) do
    for {analysis, {:error, reason}} <- Enum.sort(located),
        do: %{analysis: analysis, reason: reason}
  end

  @doc "The extraction errors among the notices."
  @spec extraction_errors(t()) :: [extraction_error()]
  def extraction_errors(%__MODULE__{notices: notices}),
    do: for({:extraction_error, error} <- notices, do: error)

  @doc "The duplicate modules among the notices."
  @spec duplicates(t()) :: [duplicate()]
  def duplicates(%__MODULE__{notices: notices}),
    do: for({:duplicate, duplicate} <- notices, do: duplicate)

  @doc "Whether the run found no solver."
  @spec souffle_missing?(t()) :: boolean()
  def souffle_missing?(%__MODULE__{notices: notices}), do: :souffle_missing in notices

  @doc """
  Every placed finding as the entries scry rendered, grouped by file: the
  line refined from the source by the finding's `at_source`, the span
  closed by its `to_block` where the bytecode left it open, `{guard}` in
  its prose filled with the keyword the source shows, and its related
  frames likewise; a finding or frame outside the program is left out.

  The frontends render from these until `Argus.Report` builds from
  `located` itself.
  """
  @spec findings_by_file(t()) :: %{optional(String.t()) => [map()]}
  def findings_by_file(%__MODULE__{located: located}) do
    for {_analysis, {:ok, placed}} <- located,
        %Argus.Located{file: file} = one <- placed,
        file != nil,
        reduce: %{} do
      acc -> Map.update(acc, file, [entry(one)], &(&1 ++ [entry(one)]))
    end
  end

  defp entry(%Argus.Located{finding: finding, file: path} = located) do
    line = Source.Elixir.refine(path, located.line, Map.get(finding, :at_source))
    guard = guard_word(path, line, finding)

    %{
      file: path,
      line: line,
      end_line: located.end_line || Source.Elixir.block_end(path, line, finding[:to_block]),
      severity: finding.severity,
      code: Atom.to_string(finding.analysis),
      title: fill_guard(finding.title, guard),
      detail: fill_guard(finding.detail, guard),
      at_label: fill_guard(Map.get(finding, :at_label), guard),
      help: Enum.map(Map.get(finding, :help, []), &fill_guard(&1, guard)),
      related: related(Map.get(finding, :related, []), located.related),
      provenance: Map.get(finding, :provenance, :structural),
      confidence: Map.get(finding, :confidence)
    }
  end

  defp related(frames, places) do
    for {frame, %{file: file} = place} <- Enum.zip(frames, places), file != nil do
      line = Source.Elixir.refine(file, place.line, Map.get(frame, :at_source))

      %{
        label: fill_guard(Map.get(frame, :label, ""), guard_word(file, line, frame)),
        file: file,
        line: line,
        end_line: place.end_line || Source.Elixir.block_end(file, line, frame[:to_block])
      }
    end
  end

  # The word for `{guard}` in a finding's prose: the keyword the source
  # shows at the anchor when the finding sits in a guard, else the
  # neutral one.
  defp guard_word(path, line, anchored) do
    if Map.get(anchored, :to_block) == :guard,
      do: Source.Elixir.guard_keyword(path, line) || "handler",
      else: "handler"
  end

  defp fill_guard(nil, _word), do: nil
  defp fill_guard(text, word), do: String.replace(text, "{guard}", word)
end
