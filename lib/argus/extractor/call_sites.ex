defmodule Argus.Extractor.CallSites do
  @moduledoc """
  Every call instruction in a module, indexed once.

  The pipeline shares this index between extractors, avoiding repeated scans
  of the instruction stream. Each site carries its target, function ID,
  instruction list and position for register resolution.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.InstrId

  @type site :: %{
          func_id: String.t(),
          instrs: [tuple()],
          idx: non_neg_integer(),
          mfa: {module(), atom(), arity()},
          remote?: boolean()
        }

  @doc "Indexes every remote and local call in `functions`."
  @spec index(module(), [tuple()]) :: [site()]
  def index(mod, functions) do
    Enum.flat_map(functions, fn {:function, name, arity, _entry, instrs} ->
      func_id = InstrId.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn {instr, idx} ->
        case Helpers.match_remote_call(instr) do
          {:ok, m, f, a} ->
            [%{func_id: func_id, instrs: instrs, idx: idx, mfa: {m, f, a}, remote?: true}]

          :none ->
            case Helpers.match_local_call(instr) do
              {:ok, m, f, a} ->
                [%{func_id: func_id, instrs: instrs, idx: idx, mfa: {m, f, a}, remote?: false}]

              :none ->
                []
            end
        end
      end)
    end)
  end

  @doc """
  The index for `module_data`: the one the pipeline attached, or a fresh
  one when an extractor is called on bare disassembly (as its unit tests
  do).
  """
  @spec for_module(map()) :: [site()]
  def for_module(%{call_sites: sites}) when is_list(sites), do: sites
  def for_module(%{module: mod, functions: functions}), do: index(mod, functions)

  # A higher-order call hands each element of its collection to the fun it
  # runs: `Map.new(params, fn {k, v} -> ... end)` runs the closure on data
  # made of `params`, which the fun takes as its first parameter.
  # {collection position, fun position}.
  @element_calls %{
    {Enum, :map, 2} => {0, 1},
    {Enum, :flat_map, 2} => {0, 1},
    {Enum, :each, 2} => {0, 1},
    {Enum, :filter, 2} => {0, 1},
    {Enum, :reject, 2} => {0, 1},
    {Enum, :find, 2} => {0, 1},
    {Enum, :group_by, 2} => {0, 1},
    {Enum, :sort_by, 2} => {0, 1},
    {Enum, :uniq_by, 2} => {0, 1},
    {Enum, :reduce, 3} => {0, 2},
    {Enum, :into, 3} => {0, 2},
    {Enum, :map_join, 3} => {0, 2},
    {Enum, :map_join, 2} => {0, 1},
    {Enum, :reduce, 2} => {0, 1},
    {Map, :new, 2} => {0, 1},
    {:lists, :map, 2} => {1, 0},
    {:lists, :foreach, 2} => {1, 0},
    {:lists, :filter, 2} => {1, 0},
    {:lists, :flatmap, 2} => {1, 0},
    {:lists, :foldl, 3} => {2, 0},
    {:lists, :foldr, 3} => {2, 0}
  }

  @doc """
  The collection and fun positions of a higher-order call that runs its
  fun on each element of its collection, the element as the fun's first
  parameter.
  """
  @spec element_call(mfa()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | :error
  def element_call(mfa), do: Map.fetch(@element_calls, mfa)

  @doc """
  The calls a higher-order call makes of a function it is handed by name
  (`Enum.each(urls, &:httpc.request/1)`), one per element of its
  collection, each as a call site of that function at the higher-order
  call: `mfa` the captured function's, `element` the register its one
  argument reads (the collection's), `via` the higher-order call's. A
  capture is a value, not a call, so an extractor that knows a function by
  its call sites sees these only by asking. The registers at the site are
  the higher-order call's: an extractor reading the function's own
  argument must read `element`.
  """
  @spec element_sites(map()) :: [map()]
  def element_sites(module_data) do
    for %{remote?: true} = site <- for_module(module_data),
        {:ok, {collection, fun}} <- [element_call(site.mfa)],
        {:ok, captured} when is_function(captured, 1) <-
          [Resolve.resolve_register(site.instrs, site.idx, {:x, fun})],
        {:type, :external} <- [Function.info(captured, :type)] do
      {:module, m} = Function.info(captured, :module)
      {:name, f} = Function.info(captured, :name)
      Map.merge(site, %{mfa: {m, f, 1}, element: {:x, collection}, via: site.mfa})
    end
  end
end
