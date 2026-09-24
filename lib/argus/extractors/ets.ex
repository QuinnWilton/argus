defmodule Argus.Extractors.ETS do
  @moduledoc """
  ETS usage extractor.

  Detects ETS table creation, option configuration, and read/write/delete
  operations from BEAM bytecode. ETS operations appear as remote calls to
  the `:ets` module via `call_ext`/`call_ext_only`/`call_ext_last`.

  ## Emitted facts

  - `ets_new(id, func, name)` — table creation point
  - `ets_option(id, key, value)` — parsed option from `:ets.new/2`
  - `ets_op(id, func, table_ref, op, kind)` — ETS read/write/delete operation
  - `ets_op_param(id, pos)` — the table operand of that operation is the
    function's own parameter `pos`, so a caller's literal names the table
  - `ets_key(id, source, key)` — what identifies the key operand of an
    operation (`Argus.Extractor.Identity.key_identity/4`); for `insert`/`insert_new` the
    key is the first element of the object tuple
  - `ets_tid_arg(caller, callee, arg_pos, name)` — at some call in
    `caller`, or in the environment of a closure it builds, the argument is
    the table `:ets.new(name, ...)` returned in `caller`: an unnamed table
    handed to the code that uses it
  - `ets_table_path(id, source, root, path)` — where the table operand of
    an operation was read from (`Resolve.access_paths/4`): a literal name,
    a parameter or a local value, and the map keys read from it. Two
    tables one function was handed in one map (`%{forward: f, reverse:
    r}`) are two paths, where `ets_op` knows both by the name they were
    created with
  - `ets_value(id, pos, source, value)` — what identifies element `pos`
    (1 and up) of the object an `insert`/`insert_new` writes, as
    `ets_key` identifies element 0
  - `ets_write_order(func, first, then)` — two ETS writes in one
    function, `then` reachable from `first` in its control-flow graph
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [each_remote_call: 3, match_remote_call: 1, register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 5]
  import Argus.Extractor.Identity, only: [key_identity: 4, tuple_element_identity: 5]

  import Argus.Extractor.Resolve,
    only: [
      access_paths: 4,
      call_result_origin: 3,
      resolve_to_arg_or_atom: 3,
      map_field_of: 3,
      resolve_atom: 3,
      resolve_register: 3
    ]

  @read_ops ~w(lookup lookup_element match match_object select member
               first next last prev tab2list info foldl foldr select_count
               safe_fixtable)a

  @write_ops ~w(insert insert_new delete_object delete_all_objects update_element
                update_counter select_delete select_replace give_away rename setopts)a

  # Operations whose key is the second argument, and the ones whose key
  # is inside the object they insert.
  @keyed_ops ~w(lookup lookup_element member delete update_element update_counter take)a
  @object_ops ~w(insert insert_new)a

  # The object elements past the key that `ets_value` names: a row
  # carries a handful of columns, and the value another table is keyed
  # by sits among the first few.
  @max_value_pos 7

  @impl true
  def relations,
    do: [
      :ets_key,
      :ets_new,
      :ets_op,
      :ets_op_param,
      :ets_option,
      :ets_table_path,
      :ets_tid_arg,
      :ets_value,
      :ets_write_order
    ]

  @doc "Whether a remote call is an ETS operation, for `Argus.Extractors.Dependence`."
  @spec site?(mfa()) :: boolean()
  def site?({:ets, _func, _arity}), do: true
  def site?(_mfa), do: false

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    index = Argus.Extractor.Identity.origins_index(module_data)
    fields = table_fields(module_data)

    module_data
    |> each_remote_call(%{}, fn facts, ctx, mfa ->
      handle_call(facts, Map.put(ctx, :origins, {index, ctx.func_id}), mfa, fields)
    end)
    |> emit_tid_args(module_data)
    |> emit_write_order(module_data)
  end

  # ── Writes in order ──────────────────────────────────────────────

  # For each function with two ETS writes or more, the pairs one runs
  # before the other on some path: an ordering question the Datalog side
  # cannot ask without the instruction stream (`call_followed_by_branch`
  # is the same trade).
  defp emit_write_order(facts, module_data) do
    facts
    |> Map.get(:ets_op, [])
    |> Enum.filter(fn [_id, _func, _table, _op, kind] -> kind == "write" end)
    |> Enum.group_by(fn [_id, func | _] -> func end, fn [id | _] -> id end)
    |> Enum.filter(fn {_func, ids} -> match?([_, _ | _], ids) end)
    |> Enum.sort()
    |> Enum.reduce(facts, fn {func, ids}, acc ->
      {name, arity} = Normalize.func_id_name_arity(func)

      case Helpers.cfg(module_data, name, arity) do
        nil ->
          acc

        fun ->
          at = Map.new(ids, fn id -> {id, instr_idx(id)} end)

          for first <- Enum.sort(ids),
              then <- Enum.sort(ids),
              first != then,
              reaches?(fun, at[first], at[then]),
              reduce: acc do
            inner -> add_fact(inner, :ets_write_order, [func, first, then])
          end
      end
    end)
  end

  defp instr_idx(id) do
    {:ok, %InstrId{idx: idx}} = InstrId.parse(id)
    idx
  end

  # Whether control can pass from instruction `from` to instruction `to`:
  # later in the same block, or in a block the edges lead to (the same
  # block again, round a loop).
  defp reaches?(fun, from, to) do
    case {Cfg.Function.block_at(fun, from), Cfg.Function.block_at(fun, to)} do
      {nil, _} -> false
      {_, nil} -> false
      {%{id: same}, %{id: same}} when from < to -> true
      {a, %{id: target}} -> reach_block(fun, successors(a), target, %{})
    end
  end

  defp reach_block(_fun, [], _target, _seen), do: false

  defp reach_block(fun, [id | rest], target, seen) do
    cond do
      id == target ->
        true

      Map.has_key?(seen, id) ->
        reach_block(fun, rest, target, seen)

      true ->
        next = successors(Map.fetch!(fun.blocks, id))
        reach_block(fun, next ++ rest, target, Map.put(seen, id, true))
    end
  end

  defp successors(%Cfg.Block{succs: succs}), do: Enum.map(succs, &elem(&1, 0))

  # ── Tables handed on ─────────────────────────────────────────────

  # A table ref leaves the function that created it as a call argument or
  # a closure's captured variable. Only the first @max_args positions, as
  # call_arg: the table sits early in every calling convention.
  @max_args 4

  defp emit_tid_args(facts, module_data) do
    facts =
      module_data
      |> CallSites.for_module()
      |> Enum.reduce(facts, fn %{func_id: func_id, instrs: instrs, idx: idx, mfa: {m, f, a}},
                               acc ->
        callee = Normalize.func_id(m, f, a)

        Enum.reduce(0..(min(a, @max_args) - 1)//1, acc, fn pos, inner ->
          tid_arg(inner, instrs, idx, {:x, pos}, [func_id, callee, to_string(pos)])
        end)
      end)

    for {:function, name, arity, _entry, instrs} <- module_data.functions,
        func_id = Normalize.func_id(module_data.module, name, arity),
        {{:make_fun3, {cmod, cname, carity}, _i, _u, _dst, {:list, env}}, idx} <-
          Enum.with_index(instrs),
        {operand, pos} <- Enum.with_index(env, carity - length(env)),
        {kind, _n} = reg <- [register(operand)],
        kind in [:x, :y],
        reduce: facts do
      acc ->
        closure = Normalize.func_id(cmod, cname, carity)
        tid_arg(acc, instrs, idx, reg, [func_id, closure, to_string(pos)])
    end
  end

  defp tid_arg(facts, instrs, idx, reg, prefix) do
    with {:ok, {:ets, :new, 2}, new_idx} <- call_result_origin(instrs, idx, reg),
         name when name != "dynamic" <- resolve_atom(instrs, new_idx, {:x, 0}) do
      add_fact(facts, :ets_tid_arg, prefix ++ [name])
    else
      _ -> facts
    end
  end

  defp handle_call(facts, ctx, {:ets, :new, 2}, _fields) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    table_name = resolve_atom(ctx.instrs, ctx.idx, {:x, 0})
    {options, facts} = resolve_options(facts, ctx)

    facts
    |> track_dynamic(table_name, ctx, :ets_table_name_new, :ets_new)
    |> add_fact(:ets_new, [id, ctx.func_id, table_name])
    |> emit_options(id, options)
  end

  defp handle_call(facts, ctx, {:ets, func, arity}, fields) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    table_ref = resolve_table(ctx, fields)
    kind = classify_op(func, arity)

    facts
    |> track_dynamic(table_ref, ctx, :ets_table_ref_op, :ets_op)
    |> add_fact(:ets_op, [id, ctx.func_id, table_ref, to_string(func), kind])
    |> maybe_table_param(id, table_ref, ctx)
    |> table_path(id, ctx)
    |> maybe_key(id, ctx, func)
    |> maybe_values(id, ctx, func)
  end

  defp handle_call(facts, _ctx, _mfa, _fields), do: facts

  defp maybe_key(facts, id, ctx, func) when func in @keyed_ops do
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 1}, ctx.origins)
    add_fact(facts, :ets_key, [id, source, key])
  end

  # The key of an inserted object is its first element; a list of objects
  # says nothing about any one key.
  defp maybe_key(facts, id, ctx, func) when func in @object_ops do
    {source, key} = tuple_element_identity(ctx.instrs, ctx.idx, {:x, 1}, 0, ctx.origins)
    add_fact(facts, :ets_key, [id, source, key])
  end

  defp maybe_key(facts, _id, _ctx, _func), do: facts

  # The table operand's access path. Emitted for every operation whose
  # operand has one, a literal name included, so a rule can join on
  # paths alone.
  defp table_path(facts, id, ctx) do
    for {source, root, path} <- access_paths(ctx.instrs, ctx.idx, {:x, 0}, ctx.func_id),
        reduce: facts do
      acc -> add_fact(acc, :ets_table_path, [id, source, root, path])
    end
  end

  # The identities of an inserted object's elements past the key. An
  # element nothing identifies is left out, as is a list of objects.
  defp maybe_values(facts, id, ctx, func) when func in @object_ops do
    for pos <- 1..@max_value_pos,
        {source, value} =
          tuple_element_identity(ctx.instrs, ctx.idx, {:x, 1}, pos, ctx.origins),
        source != "dynamic",
        reduce: facts do
      acc -> add_fact(acc, :ets_value, [id, to_string(pos), source, value])
    end
  end

  defp maybe_values(facts, _id, _ctx, _func), do: facts

  # A dynamic table operand that is the function's own parameter: the
  # name arrives from a caller, which `call_arg` can supply.
  defp maybe_table_param(facts, id, "dynamic", ctx) do
    case resolve_to_arg_or_atom(ctx.instrs, ctx.idx, {:x, 0}) do
      {:arg, pos} -> add_fact(facts, :ets_op_param, [id, to_string(pos)])
      _ -> facts
    end
  end

  defp maybe_table_param(facts, _id, _table_ref, _ctx), do: facts

  # Resolve the table operand (x0) of an ETS operation.
  #
  # The common miss is a table REFERENCE: `t = :ets.new(:cache, opts)`
  # followed by `:ets.insert(t, ...)` — x0 holds an opaque ref, not the
  # name atom. When the ref traces back (through move chains) to an
  # `:ets.new/2` call in the same function, the op inherits that
  # creation site's table name, so ops join `ets_new` rows in the
  # Datalog rules exactly like named-table ops do. A ref read from a map
  # field (`state.table`) takes the name of the table this module stores
  # under that field (`table_fields/1`) — the server that creates its
  # table in init/1 and uses it in its callbacks. Anything else stays
  # "dynamic".
  defp resolve_table(ctx, fields) do
    case resolve_atom(ctx.instrs, ctx.idx, {:x, 0}) do
      "dynamic" ->
        case call_result_origin(ctx.instrs, ctx.idx, {:x, 0}) do
          {:ok, {:ets, :new, 2}, new_idx} -> resolve_atom(ctx.instrs, new_idx, {:x, 0})
          _ -> field_table(ctx, fields)
        end

      name ->
        name
    end
  end

  defp field_table(ctx, fields) do
    with {:ok, key} <- map_field_of(ctx.instrs, ctx.idx, {:x, 0}),
         {:ok, name} <- Map.fetch(fields, key) do
      name
    else
      _ -> "dynamic"
    end
  end

  # %{field => table name}: the map fields this module stores a table
  # under — `%{state | table: :ets.new(:cache, ...)}`, `%State{table: t}`,
  # `Map.put(state, :table, t)` — keyed as `Argus.Extractor.Resolve.map_field_of/3` spells
  # them. A field that holds two tables in the module names neither.
  defp table_fields(module_data) do
    stores =
      for {:function, _name, _arity, _entry, instrs} <- module_data.functions,
          {instr, idx} <- Enum.with_index(instrs),
          {key, value} <- stored_pairs(instrs, idx, instr),
          {:ok, {:ets, :new, 2}, new_idx} <- [call_result_origin(instrs, idx, value)],
          name = resolve_atom(instrs, new_idx, {:x, 0}),
          name != "dynamic",
          do: {key, name}

    stores
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {key, names} ->
      case Enum.uniq(names) do
        [name] -> [{key, name}]
        _ambiguous -> []
      end
    end)
    |> Map.new()
  end

  # {inspected key, value register} for each literal key a map update or
  # `:maps.put/3` (what `Map.put/3` compiles to) writes a register under.
  defp stored_pairs(_instrs, _idx, {op, _fail, _src, _dst, _live, {:list, pairs}})
       when op in [:put_map_assoc, :put_map_exact] and is_list(pairs) do
    for [{:atom, key}, value] <- Enum.chunk_every(pairs, 2),
        {kind, _} = reg <- [register(value)],
        kind in [:x, :y],
        do: {inspect(key), reg}
  end

  defp stored_pairs(instrs, idx, instr) do
    with {:ok, :maps, :put, 3} <- match_remote_call(instr),
         {:ok, key} when is_atom(key) and key != :dynamic <-
           resolve_register(instrs, idx, {:x, 0}) do
      [{inspect(key), {:x, 1}}]
    else
      _ -> []
    end
  end

  # Resolve the options list passed as the second argument to :ets.new/2.
  # Track imprecision when x1 doesn't resolve to a list — we lose the
  # ability to record per-option facts (heir, concurrency, named_table).
  defp resolve_options(facts, ctx) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 1}) do
      {:ok, opts} when is_list(opts) ->
        {opts, facts}

      _ ->
        {[], track_imprecision(facts, ctx, :ets_options_unresolved, :ets_option, :unresolvable)}
    end
  end

  # Emit ets_option facts from a parsed options list.
  defp emit_options(facts, id, options) do
    Enum.reduce(options, facts, fn opt, acc ->
      case parse_option(opt) do
        {key, value} -> add_fact(acc, :ets_option, [id, key, value])
        nil -> acc
      end
    end)
  end

  # Table type atoms.
  defp parse_option(:set), do: {"type", "set"}
  defp parse_option(:ordered_set), do: {"type", "ordered_set"}
  defp parse_option(:bag), do: {"type", "bag"}
  defp parse_option(:duplicate_bag), do: {"type", "duplicate_bag"}

  # Access atoms.
  defp parse_option(:public), do: {"access", "public"}
  defp parse_option(:protected), do: {"access", "protected"}
  defp parse_option(:private), do: {"access", "private"}

  # Named table flag.
  defp parse_option(:named_table), do: {"named_table", "true"}

  # Heir setting.
  defp parse_option({:heir, _pid, _data}), do: {"heir", "true"}
  defp parse_option({:heir, :none}), do: nil

  # Concurrency settings.
  defp parse_option({:read_concurrency, val}), do: {"read_concurrency", to_string(val)}
  defp parse_option({:write_concurrency, val}), do: {"write_concurrency", to_string(val)}

  # Unknown options are ignored.
  defp parse_option(_), do: nil

  # Classify an ETS operation into read/write/delete.
  # :ets.delete/1 is table deletion; :ets.delete/2 is key deletion (a write).
  defp classify_op(:delete, 1), do: "delete"
  defp classify_op(:delete, _arity), do: "write"
  defp classify_op(func, _arity) when func in @read_ops, do: "read"
  defp classify_op(func, _arity) when func in @write_ops, do: "write"
  defp classify_op(_func, _arity), do: "unknown"
end
