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

  What only the source can say is left to whoever reads it: a finding's
  `at_source` fragment moves `line` to the token it names, `to_block`
  closes a span the bytecode left open, and `{guard}` in the prose is the
  keyword the source shows at the anchor (`Argus.Findings`). A place is
  what the bytecode says; the source refines it.
  """

  alias Argus.Findings

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
