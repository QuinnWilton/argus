defmodule Argus.Extractor.Helpers do
  @moduledoc """
  Shared access to module instructions, attributes, call sites and dataflow.

  Scans use `each_remote_call/3`, `each_call/3`, or `scan_functions/4`.
  Accessors such as `cfg/3`, `reaching/1`, `typed/1` and `debug_info/1` reuse
  pipeline-provided data and build it when given bare disassembly.

  Related helpers:

  - `Argus.Extractor.Facts` — the rows an extractor emits, and the
    imprecision the coverage analysis records
  - `Argus.Extractor.Resolve` — what a register holds, read back through
    the writes that reach it
  - `Argus.Extractor.Identity` — what names that value, for joining two
    sites on it
  - `Argus.Extractor.Terms` — spelling and walking a literal term
  - `Argus.Extractor.Shapes` — the tuples a function returns
  """

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  @typedoc """
  Per-instruction context passed to scan handlers. Carries everything an
  extractor needs to call `Argus.Extractor.Resolve.resolve_register/3`
  against the surrounding code.
  """
  @type instr_ctx :: %{
          optional(:line_table) => %{pos_integer() => pos_integer()},
          optional(:origins) => origins(),
          required(:func_id) => String.t(),
          required(:instrs) => [tuple()],
          required(:idx) => non_neg_integer()
        }

  @type origins :: Argus.Extractor.Identity.origins()

  # --- Per-instruction scanning ---

  @doc """
  Walk every function in `functions` and every instruction within each
  function, calling `handler.(facts, ctx, instr)` for each instruction.

  `ctx` is a map with `:func_id`, `:instrs`, and `:idx` — everything an
  extractor needs to call `resolve_register/3` on the surrounding code.

  This is the standard outer loop for instruction-driven extractors.
  """
  @spec scan_functions(
          module(),
          [tuple()],
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), tuple() -> Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def scan_functions(mod, functions, facts, handler) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {instr, idx}, inner ->
        handler.(inner, %{func_id: func_id, instrs: instrs, idx: idx}, instr)
      end)
    end)
  end

  # --- Attribute helpers ---

  @doc """
  Extract behaviour modules from a module's attributes.

  Handles both `:behaviour` and `:behavior` spellings.
  """
  @spec get_behaviours(keyword()) :: [module()]
  def get_behaviours(attrs) do
    attribute_values(attrs, :behaviour) ++ attribute_values(attrs, :behavior)
  end

  @doc """
  Every value the attribute `key` holds, across all its entries in a
  module's attribute chunk, nested lists flattened.

  `List.flatten/1` did this and raised on an improper list, which Erlang
  source can store as an attribute's value (`-my_attr([a|b]).`); here an
  improper list is one value.
  """
  @spec attribute_values(keyword(), atom()) :: [term()]
  def attribute_values(attrs, key) do
    for {^key, values} <- attrs, value <- flatten_proper(values, []), do: value
  end

  defp flatten_proper(term, acc) do
    if Terms.proper_list?(term),
      do: term |> Enum.reverse() |> Enum.reduce(acc, &flatten_proper/2),
      else: [term | acc]
  end

  # --- Remote call matching ---

  @doc """
  Match a BEAM instruction as a remote (external) function call.

  Returns `{:ok, module, function, arity}` for `call_ext`, `call_ext_only`,
  and `call_ext_last` instructions, or `:none` for anything else.
  """
  @spec match_remote_call(term()) :: {:ok, module(), atom(), arity()} | :none
  def match_remote_call({:call_ext, _arity, {:extfunc, mod, func, a}}),
    do: {:ok, mod, func, a}

  def match_remote_call({:call_ext_only, _arity, {:extfunc, mod, func, a}}),
    do: {:ok, mod, func, a}

  def match_remote_call({:call_ext_last, _arity, {:extfunc, mod, func, a}, _deallocate}),
    do: {:ok, mod, func, a}

  def match_remote_call(_), do: :none

  # --- Local call matching ---

  @doc """
  Match a BEAM instruction as a local (intra-module) function call.

  Returns `{:ok, module, function, arity}` for `call`, `call_only`, and
  `call_last` instructions with MFA targets, or `:none` for anything else.
  """
  @spec match_local_call(term()) :: {:ok, module(), atom(), arity()} | :none
  def match_local_call({:call, _arity, {mod, func, a}}), do: {:ok, mod, func, a}
  def match_local_call({:call_only, _arity, {mod, func, a}}), do: {:ok, mod, func, a}
  def match_local_call({:call_last, _arity, {mod, func, a}, _deallocate}), do: {:ok, mod, func, a}
  def match_local_call(_), do: :none

  # --- Function lookup ---

  @doc """
  Find a function's instruction list by name and arity.

  Returns the instruction list, or `nil` if the function is not found.
  """
  @spec find_function([term()], atom(), non_neg_integer()) :: [term()] | nil
  def find_function(functions, name, arity) do
    Enum.find_value(functions, fn
      {:function, ^name, ^arity, _, instrs} -> instrs
      _ -> nil
    end)
  end

  # --- Label scanning ---

  @doc """
  Return instructions starting from a given label number.

  Scans forward through the instruction list for `{:label, label_num}` and
  returns all instructions from that label onward (inclusive). Returns `[]`
  if the label is not found.
  """
  @spec instructions_from_label([term()], non_neg_integer()) :: [term()]
  def instructions_from_label(instrs, label_num),
    do: Enum.drop_while(instrs, &(&1 != {:label, label_num}))

  # --- Shared readings ---

  @doc """
  Calls `handler.(facts, ctx, {mod, func, arity})` for every remote call
  in the module, from the call-site index the pipeline attached (or one
  built on the spot). `ctx` is the same `instr_ctx()` the per-instruction
  scanners pass, so `resolve_register/3` and friends work unchanged.
  """
  @spec each_remote_call(
          map(),
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), {module(), atom(), arity()} ->
             Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def each_remote_call(module_data, facts, handler) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn
      %{remote?: true, mfa: mfa} = site, acc ->
        handler.(acc, %{func_id: site.func_id, instrs: site.instrs, idx: site.idx}, mfa)

      _site, acc ->
        acc
    end)
  end

  @doc "Like `each_remote_call/3`, for remote and local calls alike."
  @spec each_call(
          map(),
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), {module(), atom(), arity()} ->
             Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def each_call(module_data, facts, handler) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn %{mfa: mfa} = site, acc ->
      handler.(acc, %{func_id: site.func_id, instrs: site.instrs, idx: site.idx}, mfa)
    end)
  end

  @doc """
  The control-flow graph of the function `ctx` is in, from the graphs
  the pipeline attached to `module_data` or built on the spot.
  """
  @spec cfg(map(), atom() | String.t(), arity()) :: Argus.Cfg.Function.t() | nil
  def cfg(%{cfg: cfgs}, name, arity) when is_map(cfgs),
    do: Map.get(cfgs, {Argus.InstrId.name(name), arity})

  def cfg(module_data, name, arity) when is_atom(name),
    do: Argus.Cfg.build_for(module_data, name, arity)

  def cfg(module_data, name, arity) when is_binary(name),
    do: cfg(module_data, String.to_atom(name), arity)

  @doc """
  The module's reaching definitions with its parameters as sources
  (`Argus.Dataflow.reaching_uses/2` with `params: true`): the ones the
  pipeline attached to `module_data` (`nil` when it could not compute
  them), or computed on the spot for bare disassembly
  (`Argus.Instr.Reaching.uses/2`).
  """
  @spec reaching(map()) :: MapSet.t(Argus.Dataflow.reaching_use()) | nil
  def reaching(%{reaching: reaching}), do: reaching

  def reaching(%{module: mod, functions: functions}),
    do: Argus.Instr.Reaching.uses(mod, functions)

  @doc """
  The module's decoded Layer-1 facts — the relations
  `Argus.Pipeline.typed_relations/0` names — from the ones the pipeline
  attached to `module_data` or emitted and decoded on the spot. `nil` when the
  facts cannot be decoded — the pipeline records the same `nil`, so an
  extractor that needs them loses only what they provide.
  """
  @spec typed(map()) :: Argus.Facts.t() | nil
  def typed(%{typed: typed}) when is_map(typed), do: typed
  def typed(%{typed: nil}), do: nil

  def typed(%{module: mod, exports: exports, attributes: attributes, functions: functions} = data) do
    mod
    |> Argus.Pipeline.Emit.emit_module(
      exports,
      Map.get(data, :imports, []),
      attributes,
      functions,
      Map.get(data, :line_table, %{})
    )
    |> Map.take(Argus.Pipeline.typed_relations())
    |> Argus.Facts.decode()
  rescue
    _ -> nil
  end

  @doc """
  The module's debug-info chunk as `:beam_lib.chunks/2` decodes it
  (`{:debug_info_v1, backend, data}`), or `:error` when there is none to
  read: the one the pipeline read for the extractors that ask
  (`module_data.debug_info`), or read on the spot from the beam the
  pipeline handed over — or, for bare disassembly, from the code path.
  An Elixir module's chunk holds its whole definition, which is why it is
  read once rather than by each extractor that wants a part of it.
  """
  @spec debug_info(map()) :: {:ok, tuple()} | :error
  def debug_info(%{debug_info: debug_info}), do: debug_info

  def debug_info(module_data) do
    with {:ok, source} <- chunk_source(module_data),
         {:ok, {_module, [debug_info: chunk]}} <- :beam_lib.chunks(source, [:debug_info]) do
      {:ok, chunk}
    else
      _ -> :error
    end
  end

  defp chunk_source(%{beam: beam}) when is_binary(beam) do
    cond do
      BeamSpy.BeamFile.beam_data?(beam) -> {:ok, beam}
      File.regular?(beam) -> {:ok, String.to_charlist(beam)}
      true -> :error
    end
  end

  defp chunk_source(%{module: mod}) do
    case :code.which(mod) do
      path when is_list(path) -> {:ok, path}
      _ -> :error
    end
  end

  @doc """
  The instructions of a module that copy registers — `move`, `fmove`,
  `swap`, `trim`. An extractor that derives
  what an instruction writes from what it reads needs them: a `trim`
  writes each kept slot from one other slot, a `swap` each register from
  the other, and deriving every write from every read mixes them
  (`copy_read/2`). Keyed by instruction ID, as the facts are.
  """
  @spec copies(map()) :: %{InstrId.t() => tuple()}
  def copies(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        func_id = Normalize.func_id(mod, name, arity),
        {instr, idx} <- Enum.with_index(instrs),
        copy?(instr),
        {:ok, id} = InstrId.parse(InstrId.mint(func_id, idx)),
        into: %{},
        do: {id, instr}
  end

  defp copy?(instr) when is_tuple(instr), do: elem(instr, 0) in [:move, :fmove, :swap, :trim]
  defp copy?(_instr), do: false

  @doc """
  The register, spelled as the facts spell it (`"y3"`), that the copy
  instruction `instr` read the value it wrote into `reg` from — `nil`
  when it wrote a literal, or did not write `reg`.
  """
  @spec copy_read(tuple(), String.t()) :: String.t() | nil
  def copy_read(instr, reg) do
    case Instr.copy_source(instr, parse_reg(reg)) do
      {kind, n} when kind in [:x, :y, :fr] -> "#{kind}#{n}"
      _literal -> nil
    end
  end

  defp parse_reg("fr" <> n), do: {:fr, String.to_integer(n)}
  defp parse_reg("x" <> n), do: {:x, String.to_integer(n)}
  defp parse_reg("y" <> n), do: {:y, String.to_integer(n)}

  @doc "The graph of the function an `instr_ctx()` is in."
  @spec cfg(map(), instr_ctx()) :: Argus.Cfg.Function.t() | nil
  def cfg(module_data, %{func_id: func_id}) do
    {name, arity} = Normalize.func_id_name_arity(func_id)
    cfg(module_data, name, arity)
  end
end
