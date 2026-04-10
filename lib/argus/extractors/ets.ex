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
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      resolve_atom: 3,
      resolve_register: 3,
      scan_remote_calls: 3,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  @read_ops ~w(lookup lookup_element match match_object select member
               first next last prev tab2list info foldl foldr select_count
               safe_fixtable)a

  @write_ops ~w(insert insert_new delete_object delete_all_objects update_element
                update_counter select_delete select_replace give_away rename setopts)a

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    scan_remote_calls(module_data.module, module_data.functions, &handle_call/3)
  end

  defp handle_call(facts, ctx, {:ets, :new, 2}) do
    id = "#{ctx.func_id}##{ctx.idx}"
    table_name = resolve_atom(ctx.instrs, ctx.idx, {:x, 0})
    {options, facts} = resolve_options(facts, ctx)

    facts
    |> track_dynamic(table_name, ctx, :ets_table_name_new, :ets_new)
    |> add_fact(:ets_new, [id, ctx.func_id, table_name])
    |> emit_options(id, options)
  end

  defp handle_call(facts, ctx, {:ets, func, arity}) do
    id = "#{ctx.func_id}##{ctx.idx}"
    table_ref = resolve_atom(ctx.instrs, ctx.idx, {:x, 0})
    kind = classify_op(func, arity)

    facts
    |> track_dynamic(table_ref, ctx, :ets_table_ref_op, :ets_op)
    |> add_fact(:ets_op, [id, ctx.func_id, table_ref, to_string(func), kind])
  end

  defp handle_call(facts, _ctx, _mfa), do: facts

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
