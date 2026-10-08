defmodule Argus.Located do
  @moduledoc """
  A finding placed in the program's source by its bytecode alone.

  A finding (`t:Argus.Findings.finding/0`) names where it is by the
  program's own terms — a module, a function, an instruction — and
  never by a line: an edit that only moves lines leaves every finding
  as it was. Placing it is a step of its own, taken last, over each
  module's line table:

    * `file` is the source file the anchor's module was compiled from
      (nil for a module the program does not hold: a finding anchored
      outside it has no place to show);
    * `line` is the line the anchor's instruction is on, else its
      function's first line, else the line its module is declared on,
      else 1;
    * `end_line` is the line a span closes on (`to_instr`), when the
      bytecode puts it after `line`, else nil.

  `related` holds one place for each of the finding's related frames,
  in order, found the same way (`file` nil for a frame outside the
  program).

  What only the source can say is its last step (`refine/1`, over
  `Argus.Locate.Source`): a finding's `at_source` fragment moves `line`
  to the token it names, `to_block` closes a span the bytecode left
  open, and `{guard}` in the prose is the keyword the source shows at
  the anchor (`Argus.Findings`). A place is what the bytecode says; the
  source refines it.
  """

  alias Argus.Findings
  alias Argus.Locate.Source

  @enforce_keys [:finding, :file, :line, :end_line, :related]
  defstruct [:finding, :file, :line, :end_line, :related]

  @typedoc "Where a finding or a frame sits, as the bytecode says (see the moduledoc)."
  @type place :: %{
          file: String.t() | nil,
          line: pos_integer() | nil,
          end_line: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          finding: Findings.finding(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          related: [place()]
        }

  @doc "A place nothing resolved: a module outside the program."
  @spec nowhere() :: place()
  def nowhere, do: %{file: nil, line: nil, end_line: nil}

  @doc """
  The place refined by the source (`Argus.Locate.Source` picks the
  rules by the file's extension), the finding's and each frame's:

    * `line` is moved to the fragment the anchor names (`at_source`)
      when the source has it at or after the bytecode's line (a
      generated Erlang file's `-file` directives renumber lines first);
    * `end_line`, when the bytecode left the span open, is the end of
      the block the anchor sits in (`to_block`), else nil;
    * `{guard}` in the finding's title, detail, label and help (a
      frame's label) is the keyword the source shows at the anchor when
      it sits in a guard, and `handler` otherwise.

  A finding or frame with no file (outside the program) is left as the
  bytecode placed it, its `{guard}` unfilled. Every frontend's report
  (`Argus.Report.Entry`) and `Argus.run_analyses/2` refine the same way.
  """
  @spec refine(t()) :: t()
  def refine(%__MODULE__{finding: finding, related: places} = located) do
    {place, guard} = refine_place(located, finding)
    frames = finding.related

    {frames, places} =
      if length(frames) == length(places) do
        frames
        |> Enum.zip_with(places, fn frame, place ->
          {place, guard} = refine_place(place, frame)
          {fill_fields(frame, [:label], guard), place}
        end)
        |> Enum.unzip()
      else
        raise ArgumentError, "a place for each related frame, got: #{inspect(located)}"
      end

    finding =
      finding
      |> fill_fields([:title, :detail, :at_label, :help], guard)
      |> Map.put(:related, frames)

    %{located | finding: finding, line: place.line, end_line: place.end_line, related: places}
  end

  # The source's last step for one anchor: its place, and the word its
  # prose's `{guard}` stands for (nil without a source to read).
  defp refine_place(%{file: nil} = place, _anchored),
    do: {Map.take(place, [:file, :line, :end_line]), nil}

  defp refine_place(%{file: file} = place, anchored) do
    rules = Source.for(file)
    line = rules.refine(file, rules.line(file, place.line), anchored.at_source)
    to_block = anchored.to_block

    guard =
      if to_block == :guard,
        do: rules.guard_keyword(file, line) || "handler",
        else: "handler"

    end_line =
      case place.end_line do
        nil -> rules.block_end(file, line, to_block)
        end_line -> rules.line(file, end_line)
      end

    {%{file: file, line: line, end_line: end_line}, guard}
  end

  defp fill_fields(map, _fields, nil), do: map

  defp fill_fields(map, fields, guard),
    do: Enum.reduce(fields, map, fn field, map -> Map.update!(map, field, &fill(&1, guard)) end)

  defp fill(nil, _guard), do: nil
  defp fill(texts, guard) when is_list(texts), do: Enum.map(texts, &fill(&1, guard))

  defp fill(text, guard), do: String.replace(text, "{guard}", guard)

  @doc """
  The finding with its place written into it: `file`, `line` and
  `end_line` on the finding and on each related frame, as
  `Argus.run_analyses/2` returns them.
  """
  @spec to_finding(t()) :: Findings.finding()
  def to_finding(%__MODULE__{finding: finding, related: places} = located) do
    frames = Map.get(finding, :related, [])

    related =
      if length(frames) == length(places),
        do: Enum.zip_with(frames, places, &Map.merge/2),
        else: raise(ArgumentError, "a place for each related frame, got: #{inspect(located)}")

    Map.merge(finding, %{
      file: located.file,
      line: located.line,
      end_line: located.end_line,
      related: related
    })
  end
end
