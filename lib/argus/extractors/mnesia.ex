defmodule Argus.Extractors.Mnesia do
  @moduledoc """
  Mnesia's dirty operations: the reads and writes outside a transaction.

  `:mnesia.transaction/1` serializes what runs inside it. The `dirty_*`
  operations do not, and a `dirty_read` whose result decides or feeds a
  `dirty_write` of the same record is a read–modify–write another process
  can interleave — the race Christakis and Sagonas (2010) found in the
  snmp agent's time-stamp table.

  ## Emitted facts

  - `mnesia_op(id, func, op, kind, table_source, table, key_source, key)`
    — a dirty read (`dirty_read`, `dirty_match_object`, `dirty_select`,
    `dirty_index_read`, `dirty_index_match_object`) or write (`dirty_write`, `dirty_delete`,
    `dirty_delete_object`), or a write that is not dirty but changes the
    table under one (a transaction's `write`, `delete` or
    `delete_object`, and `dirty_update_counter`), with the table and the key it touches in the
    vocabulary of `Identity.key_identity/3`. The one-argument forms carry
    both in a tuple: `dirty_read({table, key})`, `dirty_delete({table,
    key})`, and a record whose first element is its table and whose
    second is its key. A read that finds records by something other than
    their key — a match spec, a secondary index, a pattern whose key is
    `:_` — reads every key of its table: `any`.
  - `mnesia_write_order(func, first, then)` — two of the function's writes
    (`kind` "write" above), `then` reachable from `first` within one trip
    through the function (`Argus.Cfg.Function.precedes?/3`). Two writes
    ordered neither way are on paths that exclude each other: the two
    branches of an upsert, `[] -> write(new); [r] -> write(update(r))`.

  A closure handed to a dirty activity — `async_dirty/1`, `sync_dirty/1`,
  `ets/1`, or `activity/2` with one of those contexts — runs its plain
  `read`, `write`, `delete`, `delete_object`, `match_object`, `select`
  and `index_read` without locks: each is extracted as its dirty twin
  (`op` `dirty_read`, `dirty_write`, ...). Only the closure's own calls:
  a helper it calls is not known to run in the activity.

  `dirty_update_counter` is atomic — the fix, not the bug — and a
  transaction's operations are isolated from each other; neither is a
  dirty act, but both write the table, and a dirty read-modify-write that
  one lands between loses it. The rules tell them apart by `op`. A
  transactional `read` is not extracted.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Identity
  alias Argus.Extractor.Resolve
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize
  import Argus.Extractor.Helpers, only: [each_remote_call: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Identity, only: [key_identity: 4, tuple_element_identity: 5]

  # {op, arity} => {kind, where the table is, where the key is}, each an
  # argument register or {register, element}.
  @ops %{
    {:dirty_read, 1} => {"read", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_read, 2} => {"read", {:x, 0}, {:x, 1}},
    {:dirty_match_object, 1} => {"read", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_match_object, 2} => {"read", {:x, 0}, {{:x, 1}, 1}},
    {:dirty_select, 2} => {"read", {:x, 0}, :any},
    {:dirty_index_read, 3} => {"read", {:x, 0}, :any},
    {:dirty_index_match_object, 2} => {"read", {:x, 0}, :any},
    {:dirty_write, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_write, 2} => {"write", {:x, 0}, {{:x, 1}, 1}},
    {:dirty_delete, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_delete, 2} => {"write", {:x, 0}, {:x, 1}},
    {:dirty_delete_object, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_delete_object, 2} => {"write", {:x, 0}, {{:x, 1}, 1}},
    # Writes that are not dirty acts, but change the table under one:
    # a transaction's writes (a dirty operation takes no lock, so a
    # transaction can write between a dirty read and its dirty write), and
    # the atomic counter.
    {:write, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:write, 3} => {"write", {:x, 0}, {{:x, 1}, 1}},
    {:delete, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:delete, 3} => {"write", {:x, 0}, {:x, 1}},
    {:delete_object, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:delete_object, 3} => {"write", {:x, 0}, {{:x, 1}, 1}},
    {:dirty_update_counter, 2} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_update_counter, 3} => {"write", {:x, 0}, {:x, 1}}
  }

  # A closure run in a dirty activity context is dirty throughout: its
  # plain read, write and delete take no lock (`async_dirty/1`,
  # `sync_dirty/1`, `ets/1`, or `activity/2` given one of those
  # contexts). Each op there is spelled as its dirty twin.
  @dirty_contexts [:async_dirty, :sync_dirty, :ets]

  @in_dirty_context %{
    {:read, 1} => {"dirty_read", "read", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:read, 2} => {"dirty_read", "read", {:x, 0}, {:x, 1}},
    {:read, 3} => {"dirty_read", "read", {:x, 0}, {:x, 1}},
    {:match_object, 1} => {"dirty_match_object", "read", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:match_object, 3} => {"dirty_match_object", "read", {:x, 0}, {{:x, 1}, 1}},
    {:select, 2} => {"dirty_select", "read", {:x, 0}, :any},
    {:index_read, 3} => {"dirty_index_read", "read", {:x, 0}, :any},
    {:write, 1} => {"dirty_write", "write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:write, 3} => {"dirty_write", "write", {:x, 0}, {{:x, 1}, 1}},
    {:delete, 1} => {"dirty_delete", "write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:delete, 3} => {"dirty_delete", "write", {:x, 0}, {:x, 1}},
    {:delete_object, 1} => {"dirty_delete_object", "write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:delete_object, 3} => {"dirty_delete_object", "write", {:x, 0}, {{:x, 1}, 1}}
  }

  @impl true
  def relations, do: [:mnesia_op, :mnesia_write_order]

  @doc "Whether a remote call is a Mnesia read or write extracted here, for `Argus.Extractors.Dependence`."
  @spec site?(mfa()) :: boolean()
  def site?({:mnesia, op, arity}),
    do: Map.has_key?(@ops, {op, arity}) or Map.has_key?(@in_dirty_context, {op, arity})

  def site?(_mfa), do: false

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    index = Identity.origins_index(module_data)
    returns = Identity.returned_elements(module_data, index)
    dirty = dirty_closures(module_data)

    module_data
    |> each_remote_call(%{}, fn facts, ctx, mfa ->
      ctx =
        ctx
        |> Map.put(:origins, {index, ctx.func_id, returns})
        |> Map.put(:dirty?, MapSet.member?(dirty, ctx.func_id))

      handle_call(facts, ctx, mfa)
    end)
    |> emit_write_order(module_data)
  end

  # The pairs of a function's writes one of which runs before the other
  # within one trip through it. The graph is built only for a function
  # with two writes.
  defp emit_write_order(facts, module_data) do
    facts
    |> Map.get(:mnesia_op, [])
    |> Enum.filter(fn [_id, _func, _op, kind | _] -> kind == "write" end)
    |> Enum.group_by(fn [_id, func | _] -> func end, fn [id | _] -> id end)
    |> Enum.filter(fn {_func, ids} -> length(Enum.uniq(ids)) > 1 end)
    |> Enum.sort()
    |> Enum.reduce(facts, fn {func, ids}, acc ->
      {name, arity} = Normalize.func_id_name_arity(func)
      order_writes(acc, func, Enum.uniq(ids), Helpers.cfg(module_data, name, arity))
    end)
  end

  defp order_writes(facts, _func, _ids, nil), do: facts

  defp order_writes(facts, func, ids, fun) do
    at = Map.new(ids, fn id -> {id, instr_idx(id)} end)

    for first <- ids,
        then <- ids,
        first != then,
        Argus.Cfg.Function.precedes?(fun, at[first], at[then]),
        reduce: facts do
      acc -> add_fact(acc, :mnesia_write_order, [func, first, then])
    end
  end

  defp instr_idx(id) do
    {:ok, %InstrId{idx: idx}} = InstrId.parse(id)
    idx
  end

  # The closures this module hands to a dirty activity: the make_fun3 the
  # fun operand comes from, in the function that makes the call.
  defp dirty_closures(module_data) do
    for {:function, _name, _arity, _entry, instrs} <- module_data.functions,
        {instr, idx} <- Enum.with_index(instrs),
        {:ok, :mnesia, fun, arity} <- [Helpers.match_remote_call(instr)],
        {:ok, reg} <- [dirty_fun_operand(instrs, idx, fun, arity)],
        closure = closure_made(instrs, idx, reg),
        closure != nil,
        into: MapSet.new(),
        do: closure
  end

  defp dirty_fun_operand(_instrs, _idx, fun, arity)
       when fun in [:async_dirty, :sync_dirty, :ets] and arity in [1, 2],
       do: {:ok, {:x, 0}}

  defp dirty_fun_operand(instrs, idx, :activity, arity) when arity in [2, 3, 4] do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, context} when context in @dirty_contexts -> {:ok, {:x, 1}}
      _ -> :error
    end
  end

  defp dirty_fun_operand(_instrs, _idx, _fun, _arity), do: :error

  defp closure_made(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, nil, fn
      {_at, {:make_fun3, {mod, name, arity}, _index, _uniq, _dst, _env}}, _follow ->
        Normalize.func_id(mod, name, arity)

      _writer, _follow ->
        nil
    end)
  end

  defp handle_call(facts, %{dirty?: true} = ctx, {:mnesia, op, arity} = mfa) do
    case Map.fetch(@in_dirty_context, {op, arity}) do
      {:ok, {dirty_op, kind, table_at, key_at}} ->
        add_op(facts, ctx, dirty_op, kind, table_at, key_at)

      :error ->
        handle_call(facts, %{ctx | dirty?: false}, mfa)
    end
  end

  defp handle_call(facts, ctx, {:mnesia, op, arity}) do
    case Map.fetch(@ops, {op, arity}) do
      {:ok, {kind, table_at, key_at}} ->
        add_op(facts, ctx, to_string(op), kind, table_at, key_at)

      :error ->
        facts
    end
  end

  defp handle_call(facts, _ctx, _mfa), do: facts

  defp add_op(facts, ctx, op, kind, table_at, key_at) do
    {table_source, table} = identity(ctx, table_at)
    {key_source, key} = ctx |> identity(key_at) |> wildcard()

    add_fact(facts, :mnesia_op, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      op,
      kind,
      table_source,
      table,
      key_source,
      key
    ])
  end

  defp identity(ctx, {{_kind, _n} = reg, element}),
    do: tuple_element_identity(ctx.instrs, ctx.idx, reg, element, ctx.origins)

  defp identity(_ctx, :any), do: {"any", ""}
  defp identity(ctx, reg), do: key_identity(ctx.instrs, ctx.idx, reg, ctx.origins)

  # A match pattern's `:_` key matches every key.
  defp wildcard({"literal", ":_"}), do: {"any", ""}
  defp wildcard(identity), do: identity
end
