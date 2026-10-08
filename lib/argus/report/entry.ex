defmodule Argus.Report.Entry do
  @moduledoc """
  A finding as every frontend shows it: placed in its source file, its
  place refined by the source, its prose complete.

  An entry is made from an `Argus.Located` (`from_located/1`), which is
  where the bytecode put the finding; the source takes the last step
  (`Argus.Located.refine/1`, as `Argus.run_analyses/2` takes it too):

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

  def from_located(%Argus.Located{} = located) do
    %Argus.Located{finding: finding} = refined = Argus.Located.refine(located)

    %__MODULE__{
      analysis: finding.analysis,
      severity: finding.severity,
      file: refined.file,
      line: refined.line,
      end_line: refined.end_line,
      title: finding.title,
      detail: finding.detail,
      at_label: finding.at_label,
      help: finding.help,
      related: related(finding.related, refined.related),
      provenance: finding.provenance,
      confidence: finding.confidence
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
      %{label: Map.get(frame, :label, ""), file: file, line: place.line, end_line: place.end_line}
    end
  end
end
