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
    operation (`Helpers.key_identity/3`); for `insert`/`insert_new` the
    key is the first element of the object tuple
  - `ets_guarded_write(write, read)` — the write runs only because of a
    test on the read's result, in the same function
    (`Argus.Extractor.Guard`): a read–decide–write on the table
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Guard
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      call_result_origin: 3,
      resolve_to_arg_or_atom: 3,
      each_remote_call: 3,
      find_function: 3,
      key_identity: 3,
      recent_writer: 3,
      register: 1,
      resolve_atom: 3,
      resolve_register: 3,
      track_dynamic: 5,
      track_imprecision: 5
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

  # The read–decide–write pair: a row read, and a plain write that a
  # check on it decides. insert_new, update_counter and select_replace
  # are atomic and are the fixes, not the bug.
  @deciding_reads ~w(lookup lookup_element member)
  @plain_writes ~w(insert delete delete_object update_element)

  @impl true
  def relations,
    do: [
      :ets_guarded_write,
      :ets_key,
      :ets_new,
      :ets_op,
      :ets_op_param,
      :ets_option
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    module_data
    |> each_remote_call(%{}, &handle_call/3)
    |> emit_guarded_writes(module_data)
  end

  # ── Read, then write ─────────────────────────────────────────────

  defp emit_guarded_writes(facts, module_data) do
    ops =
      facts
      |> Map.get(:ets_op, [])
      |> Enum.group_by(fn [_id, func, _table, _op, _kind] -> func end)

    Enum.reduce(ops, facts, fn {func_id, rows}, acc ->
      reads = for [id, _, _, op, _] <- rows, op in @deciding_reads, do: index_of(id)
      writes = for [id, _, _, op, _] <- rows, op in @plain_writes, do: index_of(id)
      {name, arity} = Normalize.func_id_name_arity(func_id)

      with true <- reads != [] and writes != [],
           instrs when is_list(instrs) <-
             find_function(module_data.functions, String.to_existing_atom(name), arity),
           %{} = fun <- Helpers.cfg(module_data, name, arity) do
        for read <- reads,
            {:ok, test} <- [Guard.result_test(instrs, read)],
            write <- writes,
            Guard.decides?(fun, test, write),
            reduce: acc do
          inner ->
            add_fact(inner, :ets_guarded_write, [
              InstrId.mint(func_id, write),
              InstrId.mint(func_id, read)
            ])
        end
      else
        _ -> acc
      end
    end)
  end

  defp index_of(id) do
    {:ok, %InstrId{idx: idx}} = InstrId.parse(id)
    idx
  end

  defp handle_call(facts, ctx, {:ets, :new, 2}) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    table_name = resolve_atom(ctx.instrs, ctx.idx, {:x, 0})
    {options, facts} = resolve_options(facts, ctx)

    facts
    |> track_dynamic(table_name, ctx, :ets_table_name_new, :ets_new)
    |> add_fact(:ets_new, [id, ctx.func_id, table_name])
    |> emit_options(id, options)
  end

  defp handle_call(facts, ctx, {:ets, func, arity}) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    table_ref = resolve_table(ctx)
    kind = classify_op(func, arity)

    facts
    |> track_dynamic(table_ref, ctx, :ets_table_ref_op, :ets_op)
    |> add_fact(:ets_op, [id, ctx.func_id, table_ref, to_string(func), kind])
    |> maybe_table_param(id, table_ref, ctx)
    |> maybe_key(id, ctx, func)
  end

  defp handle_call(facts, _ctx, _mfa), do: facts

  defp maybe_key(facts, id, ctx, func) when func in @keyed_ops do
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 1})
    add_fact(facts, :ets_key, [id, source, key])
  end

  # The key of an inserted object is its first element. The tuple is built
  # by put_tuple2 just before the call, or is a whole literal; a list of
  # objects, a parameter passed straight through or a call result says
  # nothing about the key. resolve_register on the tuple would lose WHICH
  # parameter an element was, so the element is resolved on its own.
  defp maybe_key(facts, id, ctx, func) when func in @object_ops do
    {source, key} =
      case recent_writer(ctx.instrs, ctx.idx, {:x, 1}) do
        {:ok, {:put_tuple2, _dst, {:list, [first | _]}}, widx} ->
          element_identity(ctx.instrs, widx, first)

        {:ok, {:move, {:literal, tuple}, _dst}, _widx}
        when is_tuple(tuple) and tuple_size(tuple) > 0 ->
          {"literal", inspect(elem(tuple, 0))}

        _ ->
          {"dynamic", ""}
      end

    add_fact(facts, :ets_key, [id, source, key])
  end

  defp maybe_key(facts, _id, _ctx, _func), do: facts

  defp element_identity(_instrs, _idx, {:atom, atom}), do: {"literal", inspect(atom)}
  defp element_identity(_instrs, _idx, {:integer, n}), do: {"literal", inspect(n)}
  defp element_identity(_instrs, _idx, {:literal, value}), do: {"literal", inspect(value)}

  defp element_identity(instrs, idx, operand) do
    case register(operand) do
      {kind, _n} = reg when kind in [:x, :y] -> key_identity(instrs, idx, reg)
      _other -> {"dynamic", ""}
    end
  end

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
  # Datalog rules exactly like named-table ops do. Refs that cross
  # function boundaries (tables held in state) stay "dynamic" — honest,
  # since the walk cannot see the creating function.
  defp resolve_table(ctx) do
    case resolve_atom(ctx.instrs, ctx.idx, {:x, 0}) do
      "dynamic" ->
        case call_result_origin(ctx.instrs, ctx.idx, {:x, 0}) do
          {:ok, {:ets, :new, 2}, new_idx} -> resolve_atom(ctx.instrs, new_idx, {:x, 0})
          _ -> "dynamic"
        end

      name ->
        name
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
