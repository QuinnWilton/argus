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

  import Argus.Extractor.Helpers, only: [add_fact: 3, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  @read_ops ~w(lookup lookup_element match match_object select member
               first next last prev tab2list info foldl foldr select_count
               safe_fixtable)a

  @write_ops ~w(insert insert_new delete_object delete_all_objects update_element
                update_counter select_delete select_replace give_away rename setopts)a

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    functions = module_data.functions

    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_instructions(facts, func_id, instrs)
    end)
  end

  defp scan_instructions(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, :ets, :new, 2} ->
          id = "#{func_id}##{idx}"
          {table_name, options} = extract_new_args(instrs, idx)
          acc = add_fact(acc, :ets_new, [id, func_id, table_name])
          emit_options(acc, id, options)

        {:ok, :ets, func, arity} ->
          id = "#{func_id}##{idx}"
          table_ref = extract_table_ref(instrs, idx)
          kind = classify_op(func, arity)
          add_fact(acc, :ets_op, [id, func_id, table_ref, to_string(func), kind])

        _ ->
          acc
      end
    end)
  end

  # Extract table name (x0) and options (x1) from preceding instructions.
  defp extract_new_args(instrs, call_idx) do
    table_name =
      case resolve_register(instrs, call_idx, {:x, 0}) do
        {:ok, atom} when is_atom(atom) -> inspect(atom)
        _ -> "dynamic"
      end

    options =
      case resolve_register(instrs, call_idx, {:x, 1}) do
        {:ok, opts} when is_list(opts) -> opts
        _ -> []
      end

    {table_name, options}
  end

  # Extract table reference (x0) from preceding instructions.
  defp extract_table_ref(instrs, call_idx) do
    case resolve_register(instrs, call_idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
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
