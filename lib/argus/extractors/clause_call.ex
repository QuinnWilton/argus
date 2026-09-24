defmodule Argus.Extractors.ClauseCall do
  @moduledoc """
  The clause each call runs in, for a function that chooses its clause
  by its first argument.

  `handle_call({:answer, n}, _, s)` and `handle_call({:echo, n}, _, s)`
  compile into one function, and so do `route(:local, n)` and
  `route(:remote, n)`: a call graph by function merges the clauses, so a
  request that enters one clause is charged with the calls of every
  other. This names, for each call, the first-argument tag the paths to
  it established (`Argus.Extractor.Dispatch.argument_tags/2`), so a rule
  can follow the clause a request or a literal argument enters.

  ## Emitted facts

  - `clause_call(id, func, tag)` — the call at `id` runs only while
    `func`'s first argument is `tag` (an atom, or a tuple headed by it,
    inspected); one row per tag some path to it establishes. A call some
    path reaches without establishing one has no row: it runs whatever
    the argument is.
  - `skipped_on_shutdown(id, func)` — the call at `id`, in a
    `terminate/2` or `terminate/3` that chooses its clause by the reason,
    does not run when the reason is `:shutdown`, the one a supervisor
    stopping the process passes (`Argus.Extractor.Dispatch.reached_with/3`):
    it sits in a clause for other reasons (`terminate(:normal, s)`), or
    after one that took `:shutdown` (`terminate(:shutdown, s)` and then
    `terminate(reason, s)`).
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Dispatch
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:clause_call, :skipped_on_shutdown]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.group_by(& &1.func_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {func_id, [%{instrs: instrs} | _] = sites}, acc ->
      if dispatches_on_first?(instrs),
        do: emit(acc, func_id, instrs, sites),
        else: acc
    end)
  end

  defp emit(facts, func_id, instrs, sites) do
    tags = Dispatch.argument_tags(instrs, {:x, 0})

    facts =
      for site <- sites,
          set = Map.get(tags, site.idx, MapSet.new([:any])),
          not MapSet.member?(set, :any),
          tag <- Enum.sort(set),
          reduce: facts do
        acc -> add_fact(acc, :clause_call, [InstrId.mint(func_id, site.idx), func_id, tag])
      end

    if terminate?(func_id), do: emit_skipped(facts, func_id, instrs, sites), else: facts
  end

  defp emit_skipped(facts, func_id, instrs, sites) do
    reached = Dispatch.reached_with(instrs, {:x, 0}, :shutdown)

    for site <- sites, not MapSet.member?(reached, site.idx), reduce: facts do
      acc -> add_fact(acc, :skipped_on_shutdown, [InstrId.mint(func_id, site.idx), func_id])
    end
  end

  # terminate/2 (GenServer) and terminate/3 (gen_statem) take the reason
  # first.
  defp terminate?(func_id),
    do: String.ends_with?(func_id, ":terminate/2") or String.ends_with?(func_id, ":terminate/3")

  # The walk is paid only by a function that compares its first argument,
  # or the first element of it, with an atom somewhere: the rest have no
  # tag to establish.
  defp dispatches_on_first?(instrs), do: Enum.any?(instrs, &tests_first?/1)

  defp tests_first?({:test, :is_tagged_tuple, _fail, [src | _]}), do: first?(src)

  defp tests_first?({:test, op, _fail, [a, b]}) when op in [:is_eq_exact, :is_ne_exact],
    do: first?(a) or first?(b)

  defp tests_first?({:select_val, src, _fail, _arms}), do: first?(src)
  defp tests_first?({:get_tuple_element, src, 0, _dst}), do: first?(src)
  defp tests_first?(_instr), do: false

  defp first?(operand), do: Instr.register(operand) == {:x, 0}
end
