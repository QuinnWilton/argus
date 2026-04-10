defmodule Argus.Pipeline.Emit do
  @moduledoc """
  Transforms normalized BEAM instructions into Layer 1 fact tuples.

  Takes the output of `Argus.Pipeline.Normalize` (a list of `{id, instruction}`
  pairs) and produces fact tuples grouped by relation name. Each fact tuple is
  a list of values matching the field order defined in `Argus.Schema`.

  ## Fact format

  Facts are returned as a map from relation name (atom) to a list of rows,
  where each row is a list of strings (ready for TSV output).
  """

  require Logger

  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @type facts :: %{atom() => [[String.t()]]}

  @doc """
  Emits facts for a single module's disassembly data.

  Takes the module name, the list of exports (for marking exported functions),
  the list of imports, the attributes, and the function definitions.
  Returns a map of relation name to list of fact rows.
  """
  @spec emit_module(atom(), list(), list(), keyword(), list()) :: facts()
  def emit_module(module, exports, imports, attributes, functions) do
    mod_str = inspect(module)

    facts = %{}

    # Module-level facts.
    facts = add_fact(facts, :module_info, [mod_str, mod_str])

    # Export set for checking if a function is exported.
    export_set =
      MapSet.new(exports, fn
        {name, arity, _label} -> {name, arity}
        # beam_disasm exports format.
        {:atom, name, arity, _label} -> {name, arity}
      end)

    # Import references.
    facts =
      Enum.reduce(imports, facts, fn
        {imod, iname, iarity}, acc ->
          add_fact(acc, :import_ref, [inspect(imod), to_string(iname), to_string(iarity)])

        {:atom, imod, {:atom, iname}, iarity}, acc ->
          add_fact(acc, :import_ref, [inspect(imod), to_string(iname), to_string(iarity)])
      end)

    # Module attributes.
    facts =
      Enum.reduce(attributes, facts, fn {key, values}, acc ->
        Enum.reduce(List.wrap(values), acc, fn val, inner_acc ->
          add_fact(inner_acc, :module_attribute, [mod_str, to_string(key), inspect(val)])
        end)
      end)

    # Process each function.
    Enum.reduce(functions, facts, fn {:function, name, arity, entry, _instrs} = func, acc ->
      func_id = Normalize.func_id(module, name, arity)

      exported =
        if MapSet.member?(export_set, {name, arity}), do: "1", else: "0"

      acc =
        add_fact(acc, :function_def, [
          func_id,
          mod_str,
          to_string(name),
          to_string(arity),
          to_string(entry),
          exported
        ])

      normalized = Normalize.normalize_function(module, func)
      emit_instructions(acc, func_id, normalized)
    end)
  end

  # Emit facts for a sequence of normalized instructions within a function.
  defp emit_instructions(facts, func_id, normalized) do
    emit_instructions_loop(facts, func_id, normalized, 0)
  end

  defp emit_instructions_loop(facts, _func_id, [], _idx), do: facts

  defp emit_instructions_loop(facts, func_id, [{id, instr} | rest], idx) do
    facts = emit_instruction_fact(facts, id, func_id, to_string(idx), instr)

    facts =
      if terminator?(instr) do
        facts
      else
        case rest do
          [{next_id, _} | _] -> add_fact(facts, :next, [id, next_id])
          [] -> facts
        end
      end

    emit_instructions_loop(facts, func_id, rest, idx + 1)
  end

  # Record the instruction fact and dispatch to specific emitters.
  defp emit_instruction_fact(facts, id, func_id, idx, instr) do
    op = instruction_op(instr)
    facts = add_fact(facts, :instruction, [id, func_id, idx, to_string(op)])
    emit_specific(facts, id, instr)
  end

  defp terminator?(:return), do: true
  defp terminator?({:jump, _}), do: true
  defp terminator?({:call_only, _, _}), do: true
  defp terminator?({:call_ext_only, _, _}), do: true
  defp terminator?({:call_last, _, _, _}), do: true
  defp terminator?({:call_ext_last, _, _, _}), do: true
  defp terminator?({:apply_last, _, _}), do: true
  defp terminator?({:func_info, _, _, _}), do: false
  defp terminator?(_), do: false

  # ── Specific emitters ─────────────────────────────────────────────

  # Label.
  defp emit_specific(facts, id, {:label, n}) do
    add_fact(facts, :label_at, [to_string(n), id])
  end

  # Line info.
  defp emit_specific(facts, id, {:line, n}) do
    add_fact(facts, :line_info, [id, to_string(n)])
  end

  # Move.
  defp emit_specific(facts, id, {:move, src, dst}) do
    facts
    |> add_fact(:move, [id, format_operand(src), format_operand(dst)])
    |> add_fact(:def, [id, format_operand(dst)])
    |> add_fact(:use, [id, format_operand(src)])
    |> maybe_literal(id, dst, src)
  end

  # Swap.
  defp emit_specific(facts, id, {:swap, a, b}) do
    facts
    |> add_fact(:def, [id, format_operand(a)])
    |> add_fact(:def, [id, format_operand(b)])
    |> add_fact(:use, [id, format_operand(a)])
    |> add_fact(:use, [id, format_operand(b)])
  end

  # Get list / head / tail.
  defp emit_specific(facts, id, {:get_list, src, hd_dst, tl_dst}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(hd_dst)])
    |> add_fact(:def, [id, format_operand(tl_dst)])
  end

  defp emit_specific(facts, id, {:get_hd, src, dst}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:get_tl, src, dst}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  # Get tuple element.
  defp emit_specific(facts, id, {:get_tuple_element, src, index, dst}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
    |> add_fact(:tuple_field_access, [
      id,
      format_operand(src),
      to_string(index),
      format_operand(dst)
    ])
  end

  # Get map elements.
  defp emit_specific(facts, id, {:get_map_elements, {:f, fail}, src, {:list, pairs}}) do
    facts = add_fact(facts, :use, [id, format_operand(src)])

    facts =
      if fail != 0 do
        add_fact(facts, :branch, [id, to_string(fail), "0"])
      else
        facts
      end

    # Pairs are [key, dst, key, dst, ...].
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(facts, fn [_key, dst], acc ->
      add_fact(acc, :def, [id, format_operand(dst)])
    end)
  end

  # Put list.
  defp emit_specific(facts, id, {:put_list, hd, tl, dst}) do
    facts
    |> add_fact(:use, [id, format_operand(hd)])
    |> add_fact(:use, [id, format_operand(tl)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  # Put tuple2.
  defp emit_specific(facts, id, {:put_tuple2, dst, {:list, elements}}) do
    facts = add_fact(facts, :def, [id, format_operand(dst)])

    Enum.reduce(elements, facts, fn elem, acc ->
      add_fact(acc, :use, [id, format_operand(elem)])
    end)
  end

  # Put map assoc / exact.
  defp emit_specific(facts, id, {put_map, {:f, fail}, src, dst, _live, {:list, pairs}})
       when put_map in [:put_map_assoc, :put_map_exact] do
    facts = add_fact(facts, :use, [id, format_operand(src)])
    facts = add_fact(facts, :def, [id, format_operand(dst)])

    facts =
      if fail != 0 do
        add_fact(facts, :branch, [id, to_string(fail), "0"])
      else
        facts
      end

    # Pairs are [key, value, key, value, ...].
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(facts, fn [_key, val], acc ->
      add_fact(acc, :use, [id, format_operand(val)])
    end)
  end

  # Update record (6-element: {op, hint, size, src, dst, {:list, updates}}).
  defp emit_specific(facts, id, {:update_record, _hint, _size, src, dst, {:list, updates}}) do
    facts = add_fact(facts, :use, [id, format_operand(src)])
    facts = add_fact(facts, :def, [id, format_operand(dst)])

    updates
    |> Enum.chunk_every(2)
    |> Enum.reduce(facts, fn [_idx, val], acc ->
      add_fact(acc, :use, [id, format_operand(val)])
    end)
  end

  # Jump.
  defp emit_specific(facts, id, {:jump, {:f, target}}) do
    add_fact(facts, :jump, [id, to_string(target)])
  end

  # Select val / select tuple arity.
  defp emit_specific(facts, id, {select_op, src, {:f, fail}, {:list, cases}})
       when select_op in [:select_val, :select_tuple_arity] do
    facts = add_fact(facts, :use, [id, format_operand(src)])

    # Emit branch to fail label.
    facts =
      if fail != 0 do
        add_fact(facts, :select_branch, [id, "_fail", to_string(fail)])
      else
        facts
      end

    # Cases are [value, {:f, label}, value, {:f, label}, ...].
    cases
    |> Enum.chunk_every(2)
    |> Enum.reduce(facts, fn [val, {:f, target}], acc ->
      add_fact(acc, :select_branch, [id, format_operand(val), to_string(target)])
    end)
  end

  # Test instructions (conditional branches).
  defp emit_specific(facts, id, {:test, test_name, {:f, fail}, args}) when is_list(args) do
    facts
    |> add_fact(:branch, [id, to_string(fail), "0"])
    |> maybe_emit_type_test(id, test_name, args, fail)
    |> emit_operand_uses(id, args)
  end

  # 5-element test form: {:test, name, fail, src_reg, {:list, fields}} (e.g. has_map_fields).
  defp emit_specific(facts, id, {:test, _test_name, {:f, fail}, src, {:list, fields}}) do
    facts = add_fact(facts, :branch, [id, to_string(fail), "0"])
    facts = add_fact(facts, :use, [id, format_operand(src)])
    emit_operand_uses(facts, id, fields)
  end

  # 5-element test form with live count: {:test, name, fail, live, args}.
  defp emit_specific(facts, id, {:test, test_name, {:f, fail}, _live, args})
       when is_list(args) do
    facts
    |> add_fact(:branch, [id, to_string(fail), "0"])
    |> maybe_emit_type_test(id, test_name, args, fail)
    |> emit_operand_uses(id, args)
  end

  # 6-element test form: {:test, name, fail, live, args, dst} (e.g. bs_start_match3, bs_get_binary2).
  defp emit_specific(facts, id, {:test, _test_name, {:f, fail}, _live, args, dst})
       when is_list(args) do
    facts = add_fact(facts, :branch, [id, to_string(fail), "0"])
    facts = add_fact(facts, :def, [id, format_operand(dst)])
    emit_operand_uses(facts, id, args)
  end

  # Local calls — modern beam_disasm uses {Module, :func, arity} tuples.
  defp emit_specific(facts, id, {:call, arity, {:f, label}}) do
    add_fact(facts, :local_call, [id, to_string(label), to_string(arity)])
  end

  defp emit_specific(facts, id, {:call, arity, {_mod, _name, _a} = mfa}) do
    facts
    |> add_fact(:local_call, [id, format_mfa(mfa), to_string(arity)])
    |> add_fact(:def, [id, "x0"])
  end

  defp emit_specific(facts, id, {:call_only, arity, {:f, label}}) do
    facts
    |> add_fact(:local_call, [id, to_string(label), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  defp emit_specific(facts, id, {:call_only, arity, {_mod, _name, _a} = mfa}) do
    facts
    |> add_fact(:local_call, [id, format_mfa(mfa), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  defp emit_specific(facts, id, {:call_last, arity, {:f, label}, _dealloc}) do
    facts
    |> add_fact(:local_call, [id, to_string(label), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  defp emit_specific(facts, id, {:call_last, arity, {_mod, _name, _a} = mfa, _dealloc}) do
    facts
    |> add_fact(:local_call, [id, format_mfa(mfa), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  # External calls.
  defp emit_specific(facts, id, {:call_ext, _arity, {:extfunc, mod, func, arity}}) do
    facts
    |> add_fact(:remote_call, [id, inspect(mod), to_string(func), to_string(arity)])
    |> add_fact(:def, [id, "x0"])
    |> maybe_spawn(id, mod, func, arity)
  end

  defp emit_specific(facts, id, {:call_ext_only, _arity, {:extfunc, mod, func, arity}}) do
    facts
    |> add_fact(:remote_call, [id, inspect(mod), to_string(func), to_string(arity)])
    |> add_fact(:tail_call, [id])
    |> maybe_spawn(id, mod, func, arity)
  end

  defp emit_specific(facts, id, {:call_ext_last, _arity, {:extfunc, mod, func, arity}, _dealloc}) do
    facts
    |> add_fact(:remote_call, [id, inspect(mod), to_string(func), to_string(arity)])
    |> add_fact(:tail_call, [id])
    |> maybe_spawn(id, mod, func, arity)
  end

  # BIF calls.
  defp emit_specific(facts, id, {:bif, func, {:f, fail}, args, dst}) do
    facts
    |> add_fact(:bif_call, [
      id,
      ":erlang",
      to_string(func),
      to_string(length(args)),
      to_string(fail)
    ])
    |> add_fact(:def, [id, format_operand(dst)])
    |> emit_operand_uses(id, args)
  end

  # BIFs that cannot fail use :nofail instead of {:f, 0} (e.g. self/0, node/0).
  defp emit_specific(facts, id, {:bif, func, :nofail, args, dst}) do
    facts
    |> add_fact(:bif_call, [
      id,
      ":erlang",
      to_string(func),
      to_string(length(args)),
      "0"
    ])
    |> add_fact(:def, [id, format_operand(dst)])
    |> emit_operand_uses(id, args)
  end

  defp emit_specific(facts, id, {:gc_bif, func, {:f, fail}, _live, args, dst}) do
    facts
    |> add_fact(:bif_call, [
      id,
      ":erlang",
      to_string(func),
      to_string(length(args)),
      to_string(fail)
    ])
    |> add_fact(:def, [id, format_operand(dst)])
    |> emit_operand_uses(id, args)
  end

  # Dynamic calls.
  defp emit_specific(facts, id, {:call_fun, _arity}) do
    add_fact(facts, :def, [id, "x0"])
  end

  defp emit_specific(facts, id, {:call_fun2, _, _, _}) do
    add_fact(facts, :def, [id, "x0"])
  end

  defp emit_specific(facts, id, {:apply, _arity}) do
    add_fact(facts, :def, [id, "x0"])
  end

  defp emit_specific(facts, id, {:apply_last, _arity, _dealloc}) do
    add_fact(facts, :tail_call, [id])
  end

  # Allocate / deallocate.
  defp emit_specific(facts, id, {:allocate, stack, live}) do
    add_fact(facts, :allocate, [id, to_string(stack), to_string(live)])
  end

  defp emit_specific(facts, id, {:allocate_heap, stack, _heap, live}) do
    add_fact(facts, :allocate, [id, to_string(stack), to_string(live)])
  end

  defp emit_specific(facts, id, {:deallocate, stack}) do
    add_fact(facts, :deallocate, [id, to_string(stack)])
  end

  # Trim.
  defp emit_specific(facts, _id, {:trim, _n, _remaining}) do
    facts
  end

  # Init Y regs.
  defp emit_specific(facts, id, {:init_yregs, {:list, regs}}) do
    Enum.reduce(regs, facts, fn reg, acc ->
      add_fact(acc, :def, [id, format_operand(reg)])
    end)
  end

  # Test heap — no facts beyond the instruction record.
  defp emit_specific(facts, _id, {:test_heap, _words, _live}) do
    facts
  end

  # Send.
  defp emit_specific(facts, id, :send) do
    facts
    |> add_fact(:send_msg, [id])
    |> add_fact(:use, [id, "x0"])
    |> add_fact(:use, [id, "x1"])
    |> add_fact(:def, [id, "x0"])
  end

  # Receive.
  defp emit_specific(facts, id, {:loop_rec, {:f, fail}, dst}) do
    facts
    |> add_fact(:recv_start, [id, to_string(fail)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:loop_rec_end, {:f, _label}}) do
    add_fact(facts, :recv_end, [id])
  end

  defp emit_specific(facts, id, :remove_message) do
    add_fact(facts, :recv_end, [id])
  end

  defp emit_specific(facts, _id, {:wait, {:f, _label}}) do
    facts
  end

  defp emit_specific(facts, _id, {:wait_timeout, {:f, _label}, _timeout}) do
    facts
  end

  defp emit_specific(facts, _id, :timeout) do
    facts
  end

  # Exception handling.
  defp emit_specific(facts, id, {:try, reg, {:f, handler}}) do
    facts
    |> add_fact(:try_start, [id, to_string(handler)])
    |> add_fact(:def, [id, format_operand(reg)])
  end

  defp emit_specific(facts, id, {:try_end, reg}) do
    facts
    |> add_fact(:try_end, [id])
    |> add_fact(:use, [id, format_operand(reg)])
  end

  defp emit_specific(facts, _id, {:try_case, _reg}) do
    facts
  end

  defp emit_specific(facts, _id, {:try_case_end, _val}) do
    facts
  end

  defp emit_specific(facts, id, {:catch, reg, {:f, handler}}) do
    facts
    |> add_fact(:try_start, [id, to_string(handler)])
    |> add_fact(:def, [id, format_operand(reg)])
  end

  defp emit_specific(facts, _id, {:catch_end, _reg}) do
    facts
  end

  defp emit_specific(facts, _id, :build_stacktrace) do
    facts
  end

  defp emit_specific(facts, _id, :raw_raise) do
    facts
  end

  # Make fun.
  defp emit_specific(facts, id, {:make_fun3, {:f, target}, _index, _uniq, dst, {:list, env}}) do
    facts
    |> add_fact(:make_fun, [id, to_string(target), to_string(length(env))])
    |> add_fact(:def, [id, format_operand(dst)])
    |> emit_operand_uses(id, env)
  end

  defp emit_specific(
         facts,
         id,
         {:make_fun3, {_mod, _name, _arity} = mfa, _index, _uniq, dst, {:list, env}}
       ) do
    closure_func = format_mfa(mfa)

    facts
    |> add_fact(:make_fun, [id, closure_func, to_string(length(env))])
    |> add_fact(:def, [id, format_operand(dst)])
    |> add_fact(:closure_def, [parent_func_id(id), closure_func])
    |> emit_operand_uses(id, env)
  end

  # Binary operations.
  defp emit_specific(facts, id, {:bs_start_match4, {:f, fail}, _live, src, dst}) do
    facts
    |> add_fact(:bs_start, [id, to_string(fail)])
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  # bs_start_match4 with {:atom, :no_fail} or {:atom, :resume} (OTP 28+).
  defp emit_specific(facts, id, {:bs_start_match4, {:atom, _mode}, _live, src, dst}) do
    facts
    |> add_fact(:bs_start, [id, "0"])
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:bs_match, {:f, fail}, ctx, {:commands, _commands}}) do
    facts
    |> add_fact(:bs_start, [id, to_string(fail)])
    |> add_fact(:use, [id, format_operand(ctx)])
  end

  defp emit_specific(facts, id, {:bs_get_tail, src, dst, _live}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:bs_get_position, src, dst, _live}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:bs_set_position, src, pos}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:use, [id, format_operand(pos)])
  end

  defp emit_specific(
         facts,
         _id,
         {:bs_create_bin, {:f, _fail}, _alloc, _live, _unit, _dst, {:list, _segs}}
       ) do
    facts
  end

  defp emit_specific(facts, _id, :bs_init_writable) do
    facts
  end

  # Float operations.
  defp emit_specific(facts, id, {:fconv, src, dst}) do
    facts
    |> add_fact(:use, [id, format_operand(src)])
    |> add_fact(:def, [id, format_operand(dst)])
  end

  defp emit_specific(facts, id, {:fmove, src, dst}) do
    facts
    |> add_fact(:move, [id, format_operand(src), format_operand(dst)])
    |> add_fact(:def, [id, format_operand(dst)])
    |> add_fact(:use, [id, format_operand(src)])
  end

  # Error instructions.
  defp emit_specific(facts, _id, {:func_info, _, _, _}) do
    facts
  end

  defp emit_specific(facts, _id, {:badmatch, _val}) do
    facts
  end

  defp emit_specific(facts, _id, {:case_end, _val}) do
    facts
  end

  defp emit_specific(facts, _id, {:badrecord, _val}) do
    facts
  end

  defp emit_specific(facts, _id, :if_end) do
    facts
  end

  # Return.
  defp emit_specific(facts, id, :return) do
    add_fact(facts, :use, [id, "x0"])
  end

  # Set tuple element (destructive update — rare).
  defp emit_specific(facts, id, {:set_tuple_element, val, tuple, _idx}) do
    facts
    |> add_fact(:use, [id, format_operand(val)])
    |> add_fact(:use, [id, format_operand(tuple)])
  end

  # Recv marker instructions — no semantic facts.
  defp emit_specific(facts, _id, {:recv_marker_bind, _, _}), do: facts
  defp emit_specific(facts, _id, {:recv_marker_clear, _}), do: facts
  defp emit_specific(facts, _id, {:recv_marker_reserve, _}), do: facts
  defp emit_specific(facts, _id, {:recv_marker_use, _}), do: facts

  # Meta instructions.
  defp emit_specific(facts, _id, {:executable_line, _, _}), do: facts
  defp emit_specific(facts, _id, {:debug_line, _}), do: facts
  defp emit_specific(facts, _id, :int_code_end), do: facts
  defp emit_specific(facts, _id, :on_load), do: facts
  defp emit_specific(facts, _id, {:on_load, _}), do: facts
  defp emit_specific(facts, _id, :nif_start), do: facts

  # Catch-all for unhandled instructions — log at debug level and record
  # an `unhandled_op` fact so we can audit production runs to find
  # opcodes the emitter is silently dropping (e.g. pre-OTP-24 shapes).
  defp emit_specific(facts, id, instr) do
    op = instruction_op(instr)
    Logger.debug("Emitter: unhandled instruction opcode: #{op}")
    add_fact(facts, :unhandled_op, [id, to_string(op)])
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp instruction_op(atom) when is_atom(atom), do: atom
  defp instruction_op(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  # Strip the "#idx" suffix from an instruction ID to recover the function ID
  # that contains it. Instruction IDs have the shape "mod:func/arity#idx".
  defp parent_func_id(instruction_id) do
    instruction_id |> String.split("#", parts: 2) |> hd()
  end

  # Unary type-test instructions narrow the type of a register on the success
  # edge. Capture the test name (which the generic `branch` fact discards)
  # so downstream analyses can reason about which register is what type.
  @type_test_names ~w(
    is_atom is_binary is_bitstring is_boolean is_float is_function is_integer
    is_list is_map is_nil is_number is_pid is_port is_reference is_tuple
  )a

  defp maybe_emit_type_test(facts, id, test_name, [reg | _], fail)
       when test_name in @type_test_names do
    add_fact(facts, :type_test, [
      id,
      to_string(test_name),
      format_operand(reg),
      to_string(fail)
    ])
  end

  defp maybe_emit_type_test(facts, _id, _test_name, _args, _fail), do: facts

  defp format_operand({:x, n}), do: "x#{n}"
  defp format_operand({:y, n}), do: "y#{n}"
  defp format_operand({:fr, n}), do: "fr#{n}"
  defp format_operand({:atom, a}), do: inspect(a)
  defp format_operand({:integer, n}), do: to_string(n)
  defp format_operand({:float, f}), do: to_string(f)
  defp format_operand({:literal, val}), do: inspect(val)
  defp format_operand(nil), do: "nil"
  defp format_operand(a) when is_atom(a), do: inspect(a)
  defp format_operand(n) when is_integer(n), do: to_string(n)
  defp format_operand({:f, n}), do: "f#{n}"
  defp format_operand(other), do: inspect(other)

  defp format_mfa({mod, name, arity}) do
    "#{inspect(mod)}:#{name}/#{arity}"
  end

  defp maybe_literal(facts, id, dst, {:integer, n}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), to_string(n)])
  end

  defp maybe_literal(facts, id, dst, {:atom, a}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), inspect(a)])
  end

  defp maybe_literal(facts, id, dst, {:literal, val}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), inspect(val)])
  end

  defp maybe_literal(facts, id, dst, {:float, f}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), to_string(f)])
  end

  defp maybe_literal(facts, id, dst, nil) do
    add_fact(facts, :literal_value, [id, format_operand(dst), "nil"])
  end

  defp maybe_literal(facts, _id, _dst, _other), do: facts

  defp maybe_spawn(facts, id, :erlang, func, arity)
       when func in [:spawn, :spawn_link, :spawn_monitor] and arity in [1, 2, 3, 4] do
    add_fact(facts, :spawn_call, [id, "dynamic", "dynamic", to_string(arity), to_string(func)])
  end

  defp maybe_spawn(facts, _id, _mod, _func, _arity), do: facts

  defp emit_operand_uses(facts, id, operands) when is_list(operands) do
    Enum.reduce(operands, facts, fn operand, acc ->
      case operand do
        {:x, _} -> add_fact(acc, :use, [id, format_operand(operand)])
        {:y, _} -> add_fact(acc, :use, [id, format_operand(operand)])
        {:fr, _} -> add_fact(acc, :use, [id, format_operand(operand)])
        _ -> acc
      end
    end)
  end
end
