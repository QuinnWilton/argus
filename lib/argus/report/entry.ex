defmodule Argus.Report.Entry do
  @moduledoc """
  A finding as every frontend shows it: placed in its source file, its
  place refined by the source, its prose complete.

  An entry is made from an `Argus.Located` (`from_located/1`), which is
  where the bytecode put the finding; the source takes the last step
  (`Argus.Locate.Source.for/1` picks its rules):

    * `line` is the bytecode's line (as the file stands: a generated
      Erlang file's `-file` directives renumber its lines), moved to the
      fragment the finding
      names (`at_source`) when the source has it at or after that line;
    * `end_line` is where the bytecode closed the span, else the end of
      the block the finding says its anchor sits in (`to_block`), else
      nil;
    * `{guard}` in the title, detail, label and help is the keyword the
      source shows at the anchor when the finding sits in a guard, and
      `handler` otherwise.

  Each related frame is refined the same way; a frame, or a finding,
  outside the program (no file) is left out.

  `file` is absolute; the renderers show it relative to where the run
  was asked from.
  """

  alias Argus.Locate.Source

  @enforce_keys [
    :analysis,
    :severity,
    :file,
    :line,
    :end_line,
    :title,
    :at_label,
    :detail,
    :help,
    :related,
    :provenance,
    :confidence
  ]
  defstruct @enforce_keys

  @typedoc "A related frame: its label and where it is."
  @type frame :: %{
          label: String.t(),
          file: String.t(),
          line: pos_integer(),
          end_line: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          analysis: atom(),
          severity: Argus.Findings.severity(),
          file: String.t(),
          line: pos_integer(),
          end_line: pos_integer() | nil,
          title: String.t(),
          at_label: String.t() | nil,
          detail: String.t(),
          help: [String.t()],
          related: [frame()],
          provenance: Argus.Findings.provenance(),
          confidence: 0..1000 | nil
        }

  @doc """
  The entry for a placed finding, or nil when the finding is outside
  the program (it has no file to show).
  """
  @spec from_located(Argus.Located.t()) :: t() | nil
  def from_located(%Argus.Located{file: nil}), do: nil

  def from_located(%Argus.Located{finding: finding, file: file} = located) do
    {line, end_line, guard} = refine(file, located, finding)

    %__MODULE__{
      analysis: finding.analysis,
      severity: finding.severity,
      file: file,
      line: line,
      end_line: end_line,
      title: fill_guard(finding.title, guard),
      detail: fill_guard(finding.detail, guard),
      # Map.get, not dot access: a finding memoized before its shape
      # gained these fields must still render.
      at_label: fill_guard(Map.get(finding, :at_label), guard),
      help: Enum.map(Map.get(finding, :help, []), &fill_guard(&1, guard)),
      related: related(Map.get(finding, :related, []), located.related),
      provenance: Map.get(finding, :provenance, :structural),
      confidence: Map.get(finding, :confidence)
    }
  end

  @doc """
  The code a finding reports under: `argus.<analysis>`.

      iex> Argus.Report.Entry.code(:mailbox)
      "argus.mailbox"
  """
  @spec code(t() | atom()) :: String.t()
  def code(%__MODULE__{analysis: analysis}), do: code(analysis)
  def code(analysis) when is_atom(analysis), do: "argus." <> Atom.to_string(analysis)

  defp related(frames, places) do
    for {frame, %{file: file} = place} <- Enum.zip(frames, places), file != nil do
      {line, end_line, guard} = refine(file, place, frame)

      %{
        label: fill_guard(Map.get(frame, :label, ""), guard),
        file: file,
        line: line,
        end_line: end_line
      }
    end
  end

  # The source's last step for one anchor: its line, the end of its
  # span, and the word its prose's `{guard}` stands for.
  defp refine(file, place, anchored) do
    rules = Source.for(file)
    line = rules.refine(file, rules.line(file, place.line), Map.get(anchored, :at_source))
    to_block = Map.get(anchored, :to_block)

    guard =
      if to_block == :guard,
        do: rules.guard_keyword(file, line) || "handler",
        else: "handler"

    end_line =
      case place.end_line do
        nil -> rules.block_end(file, line, to_block)
        end_line -> rules.line(file, end_line)
      end

    {line, end_line, guard}
  end

  defp fill_guard(nil, _word), do: nil
  defp fill_guard(text, word), do: String.replace(text, "{guard}", word)
end
