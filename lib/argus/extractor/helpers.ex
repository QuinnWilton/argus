defmodule Argus.Extractor.Helpers do
  @moduledoc """
  What every extractor reads a module through: the call sites and the
  per-instruction scan (`each_remote_call/3`, `each_call/3`,
  `scan_functions/4`), the call instructions (`match_remote_call/1`,
  `match_local_call/1`), a function's instructions and attributes
  (`find_function/3`, `instructions_from_label/2`, `get_behaviours/1`,
  `attribute_values/2`), and what the pipeline attached to the module
  data, built on the spot for bare disassembly (`cfg/3`, `reaching/1`,
  `typed/1`, `debug_info/1`, `copies/1`).

  The rest lives by concern:

  - `Argus.Extractor.Facts` — the rows an extractor emits, and the
    imprecision the coverage analysis records
  - `Argus.Extractor.Resolve` — what a register holds, read back through
    the writes that reach it
  - `Argus.Extractor.Identity` — what names that value, for joining two
    sites on it
  - `Argus.Extractor.Terms` — spelling and walking a literal term
  - `Argus.Extractor.Shapes` — the tuples a function returns

  Their functions were once here, and still answer here, deprecated.
  """

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  @type register :: Argus.Extractor.Resolve.register()

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
  def scan_functions(mod, functions, facts \\ %{}, handler) do
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
  def instructions_from_label(instrs, label_num) do
    case Enum.drop_while(instrs, fn
           {:label, ^label_num} -> false
           _ -> true
         end) do
      [] -> []
      from_label -> from_label
    end
  end

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
    do: Map.get(cfgs, {to_string(name), arity})

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

  @doc """
  A register operand with its type annotation stripped: `{:tr, reg, type}`
  becomes `reg`. Seven extractors carried a copy of this clause.
  """
  @spec register(term()) :: term()
  def register({:tr, reg, _type}), do: reg
  def register(other), do: other

  # --- Moved by concern, and deprecated here ---

  @doc false
  @deprecated "Use Argus.Extractor.Facts.add_fact/3"
  @spec add_fact(Argus.Pipeline.Emit.facts(), atom(), [String.t()]) :: Argus.Pipeline.Emit.facts()
  defdelegate add_fact(facts, relation, row), to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Facts.enable_tracing/0"
  @spec enable_tracing() :: :ok
  defdelegate enable_tracing(), to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Facts.disable_tracing/0"
  @spec disable_tracing() :: :ok
  defdelegate disable_tracing(), to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Facts.tracing_enabled?/0"
  @spec tracing_enabled?() :: boolean()
  defdelegate tracing_enabled?(), to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Facts.track_imprecision/5"
  @spec track_imprecision(
          Argus.Pipeline.Emit.facts(),
          instr_ctx(),
          atom(),
          atom(),
          atom() | String.t()
        ) :: Argus.Pipeline.Emit.facts()
  defdelegate track_imprecision(facts, ctx, category, relation, reason \\ :dynamic),
    to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Facts.track_dynamic/5"
  @spec track_dynamic(
          Argus.Pipeline.Emit.facts(),
          term(),
          instr_ctx(),
          atom(),
          atom()
        ) :: Argus.Pipeline.Emit.facts()
  defdelegate track_dynamic(facts, value, ctx, category, relation), to: Argus.Extractor.Facts

  @doc false
  @deprecated "Use Argus.Extractor.Terms.spell/1"
  @spec spell(term()) :: String.t()
  defdelegate spell(value), to: Argus.Extractor.Terms

  @doc false
  @deprecated "Use Argus.Extractor.Terms.proper_list?/1"
  @spec proper_list?(term()) :: boolean()
  defdelegate proper_list?(term), to: Argus.Extractor.Terms

  @doc false
  @deprecated "Use Argus.Extractor.Terms.list_elements/1"
  @spec list_elements(term()) :: list()
  defdelegate list_elements(term), to: Argus.Extractor.Terms

  @doc false
  @deprecated "Use Argus.Extractor.Terms.mentions?/2"
  @spec mentions?(term(), (term() -> boolean())) :: boolean()
  defdelegate mentions?(term, pred), to: Argus.Extractor.Terms

  @doc false
  @deprecated "Use Argus.Extractor.Terms.value_contains?/2"
  @spec value_contains?(term(), (term() -> boolean())) :: boolean()
  defdelegate value_contains?(value, pred), to: Argus.Extractor.Terms

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.resolve_callee/1"
  @spec resolve_callee(instr_ctx()) :: String.t()
  defdelegate resolve_callee(ctx), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.resolve_atom/3"
  @spec resolve_atom([tuple()], non_neg_integer(), register()) :: String.t()
  defdelegate resolve_atom(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.resolve_register/3"
  @spec resolve_register([term()], non_neg_integer(), register()) :: {:ok, term()} | :dynamic
  defdelegate resolve_register(instrs, call_idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.trace/5"
  @spec trace(
          [term()],
          non_neg_integer(),
          register(),
          a,
          ({:param, non_neg_integer()}
           | {non_neg_integer(), term()},
           (non_neg_integer(), register() -> a) ->
             a)
        ) :: a
        when a: term()
  defdelegate trace(instrs, idx, register, none, answer), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.map_field_of/3"
  @spec map_field_of([term()], non_neg_integer(), register()) :: {:ok, String.t()} | :dynamic
  defdelegate map_field_of(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.call_result_origin/3"
  @spec call_result_origin([term()], non_neg_integer(), register()) ::
          {:ok, {module(), atom(), arity()}, non_neg_integer()} | :no
  defdelegate call_result_origin(instrs, call_idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.recent_writer/3"
  @spec recent_writer([term()], non_neg_integer(), register()) ::
          {:ok, term(), non_neg_integer()} | :no
  defdelegate recent_writer(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.keyword_value_register/4"
  @spec keyword_value_register([term()], non_neg_integer(), register(), atom()) ::
          {:ok, register(), non_neg_integer()} | :no
  defdelegate keyword_value_register(instrs, idx, list_reg, key), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.arg_position/3"
  @spec arg_position([term()], non_neg_integer(), register()) ::
          {:ok, non_neg_integer()} | :no
  defdelegate arg_position(instrs, call_idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.resolve_to_arg_or_atom/3"
  @spec resolve_to_arg_or_atom([term()], non_neg_integer(), register()) ::
          {:atom, String.t()} | {:arg, non_neg_integer()} | :dynamic
  defdelegate resolve_to_arg_or_atom(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.fun_target/3"
  @spec fun_target([term()], non_neg_integer(), register()) :: {module(), atom(), arity()} | nil
  defdelegate fun_target(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.fun_origin/3"
  @spec fun_origin([term()], non_neg_integer(), register()) ::
          {:closure | :external, {module(), atom(), arity()}}
          | {:param, non_neg_integer()}
          | nil
  defdelegate fun_origin(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.list_length/3"
  @spec list_length([term()], non_neg_integer(), register()) :: non_neg_integer() | nil
  defdelegate list_length(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.value_at/3"
  @spec value_at([tuple()], non_neg_integer(), register()) ::
          {:literal, term()}
          | {:arg, non_neg_integer()}
          | {:call_result, {module(), atom(), arity()}, non_neg_integer()}
          | :dynamic
  defdelegate value_at(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.module_target/3"
  @spec module_target([tuple()], non_neg_integer(), register()) :: String.t()
  defdelegate module_target(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Resolve.timeout_ms/3"
  @spec timeout_ms([tuple()], non_neg_integer(), register()) :: String.t()
  defdelegate timeout_ms(instrs, idx, register), to: Argus.Extractor.Resolve

  @doc false
  @deprecated "Use Argus.Extractor.Identity.key_identity/4"
  @spec key_identity([term()], non_neg_integer(), register(), origins() | nil) ::
          {String.t(), String.t()}
  defdelegate key_identity(instrs, idx, register, origins \\ nil), to: Argus.Extractor.Identity

  @doc false
  @deprecated "Use Argus.Extractor.Identity.origins_index/1"
  @spec origins_index(map()) :: %{{String.t(), non_neg_integer(), String.t()} => [term()]}
  defdelegate origins_index(module_data), to: Argus.Extractor.Identity

  @doc false
  @deprecated "Use Argus.Extractor.Identity.tuple_element_identity/5"
  @spec tuple_element_identity(
          [term()],
          non_neg_integer(),
          register(),
          non_neg_integer(),
          origins() | nil
        ) :: {String.t(), String.t()}
  defdelegate tuple_element_identity(instrs, idx, register, n, origins \\ nil),
    to: Argus.Extractor.Identity

  @doc false
  @deprecated "Use Argus.Extractor.Shapes.return_shapes/1"
  @spec return_shapes([tuple()]) :: [{non_neg_integer(), [term()]}]
  defdelegate return_shapes(instrs), to: Argus.Extractor.Shapes
end
