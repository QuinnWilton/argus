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
    — a dirty read (`dirty_read`) or write (`dirty_write`, `dirty_delete`,
    `dirty_delete_object`), with the table and the key it touches in the
    vocabulary of `Identity.key_identity/3`. The one-argument forms carry
    both in a tuple: `dirty_read({table, key})`, `dirty_delete({table,
    key})`, and a record whose first element is its table and whose
    second is its key.

  `dirty_update_counter` is atomic — the fix, not the bug — and is not a
  write here. Neither are the transactional `read`/`write`.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Identity
  alias Argus.InstrId
  import Argus.Extractor.Helpers, only: [each_remote_call: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Identity, only: [key_identity: 4, tuple_element_identity: 5]

  # {op, arity} => {kind, where the table is, where the key is}, each an
  # argument register or {register, element}.
  @ops %{
    {:dirty_read, 1} => {"read", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_read, 2} => {"read", {:x, 0}, {:x, 1}},
    {:dirty_write, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_write, 2} => {"write", {:x, 0}, {{:x, 1}, 1}},
    {:dirty_delete, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_delete, 2} => {"write", {:x, 0}, {:x, 1}},
    {:dirty_delete_object, 1} => {"write", {{:x, 0}, 0}, {{:x, 0}, 1}},
    {:dirty_delete_object, 2} => {"write", {:x, 0}, {{:x, 1}, 1}}
  }

  @impl true
  def relations, do: [:mnesia_op]

  @doc "Whether a remote call is a dirty Mnesia read or write, for `Argus.Extractors.Dependence`."
  @spec site?(mfa()) :: boolean()
  def site?({:mnesia, op, arity}), do: Map.has_key?(@ops, {op, arity})
  def site?(_mfa), do: false

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    index = Identity.origins_index(module_data)

    each_remote_call(module_data, %{}, fn facts, ctx, mfa ->
      handle_call(facts, Map.put(ctx, :origins, {index, ctx.func_id}), mfa)
    end)
  end

  defp handle_call(facts, ctx, {:mnesia, op, arity}) do
    case Map.fetch(@ops, {op, arity}) do
      {:ok, {kind, table_at, key_at}} ->
        {table_source, table} = identity(ctx, table_at)
        {key_source, key} = identity(ctx, key_at)

        add_fact(facts, :mnesia_op, [
          InstrId.mint(ctx.func_id, ctx.idx),
          ctx.func_id,
          to_string(op),
          kind,
          table_source,
          table,
          key_source,
          key
        ])

      :error ->
        facts
    end
  end

  defp handle_call(facts, _ctx, _mfa), do: facts

  defp identity(ctx, {{_kind, _n} = reg, element}),
    do: tuple_element_identity(ctx.instrs, ctx.idx, reg, element, ctx.origins)

  defp identity(ctx, reg), do: key_identity(ctx.instrs, ctx.idx, reg, ctx.origins)
end
