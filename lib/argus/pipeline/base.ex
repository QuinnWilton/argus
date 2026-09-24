defmodule Argus.Pipeline.Base do
  @moduledoc """
  A module's base, kept: what the pipeline computes of a module before
  any extractor runs, as a binary a store holds (`keep/4`) and a later
  run reads back in place of computing it (`restore/2`).

  An extractor reads a module through its disassembly and what the
  pipeline derives from it: the decoded Layer-1 facts
  (`module_data.typed`, from the emitter's rows), the control-flow
  graphs and the reaching definitions. On a large program that is two
  fifths of extraction, and every extractor run over the module pays
  it again — after an edit to one extractor, most of the time that
  extractor's shard takes to extract. `Argus.Cache.Facts` keeps the
  bases of a set of beams keyed as it keys the base's own shard, and an
  extractor extracted again runs over them.

  ## What is kept, and what is computed again

  Each part is a compressed term of its own. Measured on the largest
  corpus checkouts, reading a part back against computing it:

    * the disassembly, without the path it was read from (the caller's
      is put back): a third of the time;
    * the control-flow graphs: a third;
    * the reaching definitions, as the per-function solutions
      `Argus.Instr.Reaching` keeps (`Argus.Instr.Reaching.export/1`),
      which the extractors' register walks go on to query: a quarter,
      and the module's `reaching` set is read off them again, as the
      pipeline reads it off its own.

  The decoded facts are not kept, only whether they could be decoded.
  They are most of the emitter's output and cost more to write than
  the other parts together — a tenth more on a cold extraction, which
  writes every base — while only three extractors read them
  (`Argus.Pipeline.typed_readers/0`); for those the pipeline emits and
  decodes them again. The call-site and origins indexes are cheaper to
  build than to decode, and the debug-info chunk is read from the beam,
  as it always is.

  A step that failed when the base was computed keeps its `nil`, so an
  extractor reads what it read then; the failure itself is the base
  shard's row.
  """

  alias Argus.Instr.Reaching

  # Moves every kept base: bump it when a part's shape changes.
  @format "argus-base-1"

  @typedoc """
  What `restore/2` reads back: the disassembly (`data`), the
  control-flow graphs, the reaching definitions, and whether the
  module's facts could be decoded (`typed?`).
  """
  @type restored :: %{
          data: map(),
          cfg: map(),
          reaching: MapSet.t() | nil,
          typed?: boolean()
        }

  @doc """
  A module's base as a binary: its disassembly (`data`), whether its
  facts were decoded (`typed`, nil when they could not be), its
  control-flow graphs, and its reaching definitions (nil when they
  were not computed). Called in the process that computed them: the
  reaching definitions are exported from its `Argus.Instr.Reaching`
  solutions.
  """
  @spec keep(map(), Argus.Facts.t() | nil, map(), MapSet.t() | nil) :: binary()
  def keep(data, typed, cfgs, reaching) do
    parts = %{
      data: data |> Map.delete(:beam) |> compress(),
      typed?: typed != nil,
      cfg: compress(cfgs),
      reaching: if(reaching, do: data.functions |> Reaching.export() |> compress())
    }

    :erlang.term_to_binary({@format, parts})
  end

  @doc """
  The base `keep/4` made, for the module read from `path`: its
  disassembly (with `path` as its `:beam`), its control-flow graphs,
  and its reaching definitions — the per-function solutions restored
  into this process first, for the extractors' walks. Raises on a
  binary `keep/4` did not make, before restoring anything.
  """
  @spec restore(binary(), String.t() | binary()) :: restored()
  def restore(kept, path) do
    {@format, parts} = :erlang.binary_to_term(kept)
    data = parts.data |> decompress() |> Map.put(:beam, path)
    cfg = decompress(parts.cfg)
    exported = if parts.reaching, do: decompress(parts.reaching)

    reaching =
      if exported do
        :ok = Reaching.restore(data.functions, exported)
        Reaching.uses(data.module, data.functions)
      end

    %{data: data, cfg: cfg, reaching: reaching, typed?: parts.typed?}
  end

  defp compress(term), do: :erlang.term_to_binary(term, compressed: 1)
  defp decompress(binary), do: :erlang.binary_to_term(binary)
end
