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

  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Disassemble
  alias Argus.Pipeline.Emit.{Applies, FunRefs, Spawns}
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @type facts :: %{atom() => [[String.t()]]}

  @doc """
  `emit_module/4` of a module's disassembly
  (`Argus.Pipeline.Disassemble.disassemble_path/1`): its exports and Line
  table when it has them, none when it does not.
  """
  @spec emit(map()) :: facts()
  def emit(%{module: module, functions: functions} = data) do
    emit_module(
      module,
      Map.get(data, :exports, []),
      functions,
      Map.get(data, :line_table, %{})
    )
  end

  @doc """
  Emits facts for a single module: its name, its exports (which mark the
  functions exported), its function definitions, and its Line-chunk
  table (`BeamSpy.Source.parse_line_table/1`), which resolves line
  markers to source lines for `line_info`
  (`Argus.Pipeline.Disassemble.marker_line/2`). Returns a map of relation
  name to fact rows.
  """
  @spec emit_module(atom(), list(), list(), map()) :: facts()
  def emit_module(module, exports, functions, line_table \\ %{}) do
    mod_str = inspect(module)

    facts = %{}

    # Export set for checking if a function is exported.
    export_set =
      MapSet.new(exports, fn
        {name, arity, _label} -> {name, arity}
        # beam_disasm exports format.
        {:atom, name, arity, _label} -> {name, arity}
      end)

    # Process each function.
    Enum.reduce(functions, facts, fn {:function, name, arity, entry, _instrs} = func, acc ->
      func_id = InstrId.func_id(module, name, arity)

      exported =
        if MapSet.member?(export_set, {name, arity}), do: "1", else: "0"

      acc =
        acc
        |> add_fact(:function_def, [
          func_id,
          mod_str,
          InstrId.name(name),
          to_string(arity),
          exported
        ])
        # Positional, and split out for that reason — see Schema.
        |> add_fact(:function_entry, [func_id, to_string(entry)])

      normalized = Normalize.normalize_function(module, func)
      emit_instructions(acc, func_id, normalized, line_table)
    end)
  end

  @doc "Source locations alone, using the same marker and exception-region rules as emission."
  @spec locations(module(), list(), map()) :: facts()
  def locations(module, functions, line_table) do
    Enum.reduce(functions, %{}, fn function, facts ->
      normalized = Normalize.normalize_function(module, function)
      location_rows(normalized, line_table, nil, facts)
    end)
  end

  defp location_rows([], _table, _line, facts), do: facts

  defp location_rows([{id, instruction} | rest], table, line, facts) do
    line = instruction_line(instruction, rest, table, line)
    location_rows(rest, table, line, emit_line_info(facts, id, line))
  end

  # A marker switches the line in effect. No location (reference 0, or
  # `[]` on OTP 29) and references the table cannot resolve switch it to
  # unknown: compiler-generated code must not inherit the previous source
  # line. OTP 28 debug builds (`beam_debug_info`) carry a debug_line
  # marker on every executable line, in the same reference space.
  defp instruction_line({:line, marker}, _rest, table, _line),
    do: Disassemble.marker_line(marker, table)

  defp instruction_line({:debug_line, _, marker, _, _}, _rest, table, _line),
    do: Disassemble.marker_line(marker, table)

  defp instruction_line(instruction, rest, table, line),
    do: region_line(instruction, rest, table, line)

  # Emit facts for a sequence of normalized instructions within a function.
  defp emit_instructions(facts, func_id, normalized, line_table) do
    facts
    |> emit_receives(func_id, normalized)
    |> emit_spawns(func_id, normalized)
    |> emit_fun_refs(func_id, normalized)
    |> emit_applies(func_id, normalized)
    |> emit_instructions_loop(func_id, normalized, 0, line_table, nil)
  end

  # A receive compiles to a loop_rec whose fail label leads to the
  # empty-mailbox block, and that block ends in either `wait` (sleep and
  # re-enter the loop — no timeout, so the process can block forever) or
  # `wait_timeout` (bounded). Which one it is decides whether a receive in
  # the wrong place is a nuisance or a hang, and it is only visible by
  # following a label, so it is resolved here.
  defp emit_receives(facts, func_id, normalized) do
    instrs = Enum.map(normalized, fn {_id, instr} -> instr end)
    labels = Instr.labels(instrs)

    Enum.reduce(normalized, facts, fn
      {id, {:loop_rec, {:f, fail}, _dst}}, acc ->
        blocking = if blocking_wait?(instrs, Map.get(labels, fail)), do: "1", else: "0"
        add_fact(acc, :recv_start, [id, func_id, blocking, to_string(fail)])

      _, acc ->
        acc
    end)
  end

  # Scan the empty-mailbox block for whichever of wait/wait_timeout comes
  # first, or a bare `timeout`: `after 0` compiles to no wait at all, the
  # empty-mailbox block going straight to the after clause's body. An
  # unresolvable label is reported as non-blocking: this feeds a "this
  # receive can hang" finding, and guessing yes without evidence would
  # put a fabricated hang in front of someone. The scan stops at the
  # first of the three: a later receive's `wait` is not this one's (io's
  # execute_request/3 flushes an :EXIT with `after 0` inside a receive
  # that waits).
  defp blocking_wait?(_instrs, nil), do: false

  defp blocking_wait?(instrs, from) do
    first =
      instrs
      |> Enum.drop(from)
      |> Enum.find(
        &(match?({:wait, _}, &1) or match?({:wait_timeout, _, _}, &1) or &1 == :timeout)
      )

    match?({:wait, _}, first)
  end

  defp emit_instructions_loop(facts, _func_id, [], _idx, _line_table, _line), do: facts

  defp emit_instructions_loop(facts, func_id, [{id, instr} | rest], idx, line_table, line) do
    line = instruction_line(instr, rest, line_table, line)

    facts = emit_instruction_fact(facts, id, func_id, to_string(idx), instr, line)

    facts =
      case rest do
        [{next_id, _} | _] ->
          if Instr.falls_through?(instr), do: add_fact(facts, :next, [id, next_id]), else: facts

        [] ->
          facts
      end

    emit_instructions_loop(facts, func_id, rest, idx + 1, line_table, line)
  end

  # A `try` or `catch` comes before the line marker of the expression it
  # protects, and often first in a block a jump enters (a clause of its
  # own), where the line in effect is whatever the listing held last —
  # another clause's: ejabberd's `parse_auth/1` put its `try
  # base64:decode(..)` on the `Bearer` clause thirteen lines below. Its
  # line is the protected expression's, the first marker after it, when
  # one comes before the next label.
  defp region_line({op, _reg, _handler}, rest, line_table, line) when op in [:try, :catch] do
    Enum.reduce_while(rest, line, fn
      {_id, {:label, _}}, line ->
        {:halt, line}

      {_id, {:line, marker}}, line ->
        {:halt, Disassemble.marker_line(marker, line_table) || line}

      {_id, {:debug_line, _kind, ref, _index, _live}}, line ->
        {:halt, Disassemble.marker_line(ref, line_table) || line}

      _other, line ->
        {:cont, line}
    end)
  end

  defp region_line(_instr, _rest, _line_table, line), do: line

  # Record the instruction fact and dispatch to specific emitters. Every
  # instruction gets a `line_info` fact for the line in effect: anchors
  # are call-site instruction IDs, so a fact only at the marker itself
  # would leave every real anchor without a line.
  defp emit_instruction_fact(facts, id, func_id, idx, instr, line) do
    op = instruction_op(instr)

    facts =
      facts
      |> add_fact(:instruction, [id, func_id, idx, to_string(op)])
      |> emit_line_info(id, line)

    case instr do
      {:line, _marker} -> facts
      {:debug_line, _kind, _ref, _index, _live} -> facts
      _ -> facts |> emit_def_use(id, instr) |> emit_specific(id, func_id, instr)
    end
  end

  # What an instruction reads and writes is `Argus.Instr`'s to say, for
  # every instruction alike; the clauses below add only the facts that are
  # particular to one. An instruction Instr cannot read is logged, so a run
  # can be audited for opcodes that would otherwise pass without a trace.
  defp emit_def_use(facts, id, instr) do
    unless Instr.known?(instr) do
      Logger.debug("Emitter: unhandled instruction opcode: #{instruction_op(instr)}")
    end

    facts =
      Enum.reduce(Instr.defs(instr), facts, &add_fact(&2, :def, [id, format_operand(&1)]))

    Enum.reduce(Instr.uses(instr), facts, &add_fact(&2, :use, [id, format_operand(&1)]))
  end

  # Instructions with no line in effect (before the first marker, or under
  # a no-location marker) produce no fact: `line_info` carries source
  # lines, never guesses.
  defp emit_line_info(facts, _id, nil), do: facts
  defp emit_line_info(facts, id, line), do: add_fact(facts, :line_info, [id, to_string(line)])

  # ── Specific emitters ─────────────────────────────────────────────

  # Call-shaped instructions take an extra `func_id` and record it as a
  # `caller` column. Rules used to recover a call's containing function by
  # joining `instruction`, which is the largest relation in the schema
  # (343k rows on a 531-module project) and moves on every body edit — so
  # every analysis reading a call also read, and re-solved on, all of it.
  # Twelve of the fourteen `instruction(...)` uses in the rule corpus were
  # exactly that decode.

  # Local calls — modern beam_disasm uses {Module, :func, arity} tuples.
  defp emit_specific(facts, id, func_id, {:call, arity, target}) do
    add_fact(facts, :local_call, [id, func_id, local_target(target), to_string(arity)])
  end

  defp emit_specific(facts, id, func_id, {:call_only, arity, target}) do
    facts
    |> add_fact(:local_call, [id, func_id, local_target(target), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  defp emit_specific(facts, id, func_id, {:call_last, arity, target, _dealloc}) do
    facts
    |> add_fact(:local_call, [id, func_id, local_target(target), to_string(arity)])
    |> add_fact(:tail_call, [id])
  end

  # External calls.
  defp emit_specific(facts, id, func_id, {:call_ext, _arity, {:extfunc, mod, func, arity}}) do
    facts
    |> add_fact(:remote_call, [id, func_id, inspect(mod), InstrId.name(func), to_string(arity)])
    |> maybe_dynamic(id, func_id, mod, func)
  end

  defp emit_specific(facts, id, func_id, {:call_ext_only, _arity, {:extfunc, mod, func, arity}}) do
    facts
    |> add_fact(:remote_call, [id, func_id, inspect(mod), InstrId.name(func), to_string(arity)])
    |> add_fact(:tail_call, [id])
    |> maybe_dynamic(id, func_id, mod, func)
  end

  defp emit_specific(
         facts,
         id,
         func_id,
         {:call_ext_last, _arity, {:extfunc, mod, func, arity}, _dealloc}
       ) do
    facts
    |> add_fact(:remote_call, [id, func_id, inspect(mod), InstrId.name(func), to_string(arity)])
    |> add_fact(:tail_call, [id])
    |> maybe_dynamic(id, func_id, mod, func)
  end

  # BIF calls. BIFs that cannot fail use :nofail instead of {:f, 0}
  # (e.g. self/0, node/0).
  defp emit_specific(facts, id, func_id, {:bif, func, fail, args, _dst}) do
    add_fact(facts, :bif_call, [
      id,
      func_id,
      ":erlang",
      to_string(func),
      to_string(length(args)),
      fail_label(fail)
    ])
  end

  defp emit_specific(facts, id, func_id, {:gc_bif, func, fail, _live, args, _dst}) do
    add_fact(facts, :bif_call, [
      id,
      func_id,
      ":erlang",
      to_string(func),
      to_string(length(args)),
      fail_label(fail)
    ])
  end

  # Exception handling.
  defp emit_specific(facts, id, func_id, {:try, _reg, {:f, handler}}) do
    add_fact(facts, :try_start, [id, func_id, "try", to_string(handler)])
  end

  defp emit_specific(facts, id, func_id, {:catch, _reg, {:f, handler}}) do
    add_fact(facts, :try_start, [id, func_id, "catch", to_string(handler)])
  end

  # Dynamic calls.
  defp emit_specific(facts, id, func_id, {:call_fun, _arity}) do
    add_fact(facts, :dynamic_call, [id, func_id, "call_fun"])
  end

  defp emit_specific(facts, id, func_id, {:call_fun2, _tag, _arity, _func}) do
    add_fact(facts, :dynamic_call, [id, func_id, "call_fun"])
  end

  defp emit_specific(facts, id, func_id, {:apply, _arity}) do
    add_fact(facts, :dynamic_call, [id, func_id, "apply"])
  end

  defp emit_specific(facts, id, func_id, {:apply_last, _arity, _dealloc}) do
    facts
    |> add_fact(:dynamic_call, [id, func_id, "apply"])
    |> add_fact(:tail_call, [id])
  end

  # Send.
  defp emit_specific(facts, id, func_id, :send) do
    add_fact(facts, :send_msg, [id, func_id])
  end

  # Make fun: a closure lifted to a concrete MFA is a closure_def edge.
  defp emit_specific(facts, id, _func_id, {:make_fun3, {_mod, _name, _arity} = mfa, _, _, _, _}) do
    add_fact(facts, :closure_def, [parent_func_id(id), format_mfa(mfa)])
  end

  # Everything else takes no `func_id`.
  defp emit_specific(facts, id, _func_id, instr), do: emit_specific(facts, id, instr)

  # Label.
  defp emit_specific(facts, id, {:label, n}) do
    add_fact(facts, :label_at, [to_string(n), id])
  end

  # Move: what it writes, when that is a literal.
  defp emit_specific(facts, id, {:move, src, dst}) do
    facts
    |> maybe_literal(id, dst, src)
    |> maybe_literal_tuple(id, dst, src)
  end

  # Put tuple2.
  defp emit_specific(facts, id, {:put_tuple2, dst, {:list, elements}}) do
    maybe_tuple_literal(facts, id, dst, elements)
  end

  # The instructions with a fail label that is not a test's: a missing
  # key, a failed map update, a failed binary construction in a guard.
  defp emit_specific(facts, id, {:get_map_elements, fail, _src, _pairs}),
    do: maybe_branch(facts, id, fail)

  defp emit_specific(facts, id, {put_map, fail, _src, _dst, _live, _pairs})
       when put_map in [:put_map_assoc, :put_map_exact],
       do: maybe_branch(facts, id, fail)

  defp emit_specific(facts, id, {:bs_create_bin, fail, _alloc, _live, _unit, _dst, _segs}),
    do: maybe_branch(facts, id, fail)

  defp emit_specific(facts, id, {:get_record_elements, fail, _src, _pairs}),
    do: maybe_branch(facts, id, fail)

  defp emit_specific(facts, id, {:put_record, fail, _id, _src, _dst, _pairs}),
    do: maybe_branch(facts, id, fail)

  # Jump.
  defp emit_specific(facts, id, {:jump, {:f, target}}) do
    add_fact(facts, :jump, [id, to_string(target)])
  end

  # Select val / select tuple arity.
  defp emit_specific(facts, id, {select_op, _src, {:f, fail}, {:list, cases}})
       when select_op in [:select_val, :select_tuple_arity] do
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
  end

  # 5-element test form: {:test, name, fail, src_reg, {:list, fields}} (e.g. has_map_fields).
  defp emit_specific(facts, id, {:test, _test_name, {:f, fail}, _src, {:list, _fields}}) do
    add_fact(facts, :branch, [id, to_string(fail), "0"])
  end

  # 5-element test form with live count: {:test, name, fail, live, args}.
  defp emit_specific(facts, id, {:test, test_name, {:f, fail}, _live, args})
       when is_list(args) do
    facts
    |> add_fact(:branch, [id, to_string(fail), "0"])
    |> maybe_emit_type_test(id, test_name, args, fail)
  end

  # 6-element test form: {:test, name, fail, live, args, dst} (e.g. bs_start_match3, bs_get_binary2).
  defp emit_specific(facts, id, {:test, _test_name, {:f, fail}, _live, args, _dst})
       when is_list(args) do
    add_fact(facts, :branch, [id, to_string(fail), "0"])
  end

  # OTP 29's native-record tests (`Argus.Instr`), which name their
  # subject bare: the fail label is where every test's is.
  defp emit_specific(facts, id, test)
       when is_tuple(test) and tuple_size(test) >= 4 and elem(test, 0) == :test do
    if record_test?(test), do: maybe_branch(facts, id, elem(test, 2)), else: facts
  end

  # Receive. The loop's control flow is real control flow: loop_rec falls
  # through on a message and branches to its fail label (the wait block) on an
  # empty mailbox; loop_rec_end and wait transfer back to the loop label; and
  # wait_timeout re-enters the loop on a message or falls through on timeout.
  # Without these edges, receive loops have no back edges in the CFG.
  # recv_start is emitted by emit_receives/3 instead: deciding whether the
  # receive can block forever means following the fail label to another
  # instruction, which a per-instruction emitter cannot see.
  defp emit_specific(facts, id, {:loop_rec, {:f, fail}, _dst}) do
    add_fact(facts, :branch, [id, to_string(fail), "0"])
  end

  defp emit_specific(facts, id, {:loop_rec_end, {:f, label}}) do
    add_fact(facts, :jump, [id, to_string(label)])
  end

  defp emit_specific(facts, id, {:wait, {:f, label}}) do
    add_fact(facts, :jump, [id, to_string(label)])
  end

  defp emit_specific(facts, id, {:wait_timeout, {:f, label}, _timeout}) do
    add_fact(facts, :branch, [id, to_string(label), "0"])
  end

  # Binary matching.
  defp emit_specific(facts, id, {:bs_start_match4, fail, _live, _src, _dst}) do
    add_fact(facts, :bs_start, [id, fail_label(fail)])
  end

  defp emit_specific(facts, id, {:bs_match, fail, _ctx, _commands}) do
    add_fact(facts, :bs_start, [id, fail_label(fail)])
  end

  # Every other instruction carries only what emit_def_use/3 records.
  defp emit_specific(facts, _id, _instr), do: facts

  # A fail label as the schema's number column: 0 when there is none
  # (`{:f, 0}`, `:nofail`, bs_start_match4's `{:atom, :no_fail}`).
  defp fail_label({:f, label}) when is_integer(label), do: to_string(label)
  defp fail_label(_no_label), do: "0"

  # A test of OTP 29's native records, in the shapes its disassembler
  # prints (`Argus.Instr`): a subject named bare, and what it asks after.
  defp record_test?({:test, :is_record, {:f, _}, src}), do: not is_list(src)
  defp record_test?({:test, :is_record, {:f, _}, _src, _module, _name}), do: true
  defp record_test?({:test, :is_record_accessible, {:f, _}, _src, _scope}), do: true
  defp record_test?({:test, :get_record_field, {:f, _}, _src, _id, _field, _dst}), do: true
  defp record_test?(_instr), do: false

  defp maybe_branch(facts, id, {:f, fail}) when is_integer(fail) and fail != 0,
    do: add_fact(facts, :branch, [id, to_string(fail), "0"])

  defp maybe_branch(facts, _id, _fail), do: facts

  defp local_target({:f, label}), do: to_string(label)
  defp local_target({_mod, _name, _arity} = mfa), do: format_mfa(mfa)

  # A tagged tuple built in place: the tag and size are what a rule
  # matching a message or return shape needs. x registers only — a y
  # register is a frame-relative stack slot that means nothing to a rule
  # matching on an argument position.
  defp maybe_tuple_literal(facts, id, {:x, n}, [{:atom, tag} | rest]) when is_atom(tag),
    do: add_fact(facts, :tuple_literal, [id, "x#{n}", inspect(tag), to_string(length(rest) + 1)])

  defp maybe_tuple_literal(facts, _id, _dst, _elements), do: facts

  # The same tagged tuple, folded by the compiler into one literal.
  defp maybe_literal_tuple(facts, id, {:x, n}, {:literal, tuple})
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do:
         add_fact(facts, :tuple_literal, [
           id,
           "x#{n}",
           inspect(elem(tuple, 0)),
           to_string(tuple_size(tuple))
         ])

  defp maybe_literal_tuple(facts, _id, _dst, _src), do: facts

  # ── Helpers ────────────────────────────────────────────────────────

  defp instruction_op(atom) when is_atom(atom), do: atom
  defp instruction_op(tuple) when is_tuple(tuple), do: elem(tuple, 0)

  # Recover the function ID containing an instruction ID. Right-anchored via
  # InstrId, because splitting on the FIRST "#" truncates compiler-generated
  # names that contain one (`-fun-#1-`-style) and yields a function ID that
  # joins against the wrong function, or none. On a malformed ID — which
  # cannot happen for IDs this module minted itself — the full ID is passed
  # through, where it simply fails to match rather than matching wrongly.
  defp parent_func_id(instruction_id) do
    case InstrId.func_id_of(instruction_id) do
      {:ok, func_id} -> func_id
      :error -> instruction_id
    end
  end

  # Type-test instructions narrow the type of a register on the success
  # edge. Capture the test name (which the generic `branch` fact discards)
  # so downstream analyses can reason about which register is what type.
  # Most are unary; `is_tagged_tuple` carries arity/tag operands and
  # `is_nonempty_list` narrows to a cons cell — both still type-test their
  # first operand, which is what the `src` field records.
  @type_test_names ~w(
    is_atom is_binary is_bitstring is_boolean is_float is_function is_integer
    is_list is_map is_nil is_nonempty_list is_number is_pid is_port
    is_reference is_tagged_tuple is_tuple
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
  defp format_operand({:literal, val}), do: spell(val)
  defp format_operand(nil), do: "nil"
  defp format_operand(a) when is_atom(a), do: inspect(a)
  defp format_operand(n) when is_integer(n), do: to_string(n)
  defp format_operand({:f, n}), do: "f#{n}"
  defp format_operand(other), do: spell(other)

  # A literal's spelling, `Terms.spell/1`, with location metadata left
  # out (`strip_location/1`).
  defp spell(val), do: val |> strip_location() |> Terms.spell()

  defp format_mfa({mod, name, arity}), do: InstrId.func_id(mod, name, arity)

  defp maybe_literal(facts, id, dst, {:integer, n}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), to_string(n)])
  end

  defp maybe_literal(facts, id, dst, {:atom, a}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), inspect(a)])
  end

  defp maybe_literal(facts, id, dst, {:literal, val}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), spell(val)])
  end

  defp maybe_literal(facts, id, dst, {:float, f}) do
    add_fact(facts, :literal_value, [id, format_operand(dst), to_string(f)])
  end

  defp maybe_literal(facts, id, dst, nil) do
    add_fact(facts, :literal_value, [id, format_operand(dst), "nil"])
  end

  defp maybe_literal(facts, _id, _dst, _other), do: facts

  # Location metadata smuggled into a literal — Logger macros embed
  # `file:`/`line:` (with `mfa:`/`module:`) in their metadata keyword —
  # is positional data, and the semantic relations must not carry it:
  # a comment above a `Logger.warning` would otherwise change a
  # `literal_value` row and re-solve every analysis that reads literals.
  # Only keywords/maps that carry BOTH `:file` and `:line` are treated as
  # locations, so a `[line: 3]` a program builds itself is untouched.
  @location_keys [:file, :line]

  defp strip_location(list) when is_list(list) do
    if location_keyword?(list) do
      list |> Keyword.drop(@location_keys) |> strip_elements()
    else
      strip_elements(list)
    end
  end

  defp strip_location(%{__struct__: _} = struct), do: struct

  defp strip_location(map) when is_map(map) do
    map =
      if Map.has_key?(map, :file) and Map.has_key?(map, :line),
        do: Map.drop(map, @location_keys),
        else: map

    Map.new(map, fn {k, v} -> {k, strip_location(v)} end)
  end

  defp strip_location(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&strip_location/1) |> List.to_tuple()
  end

  defp strip_location(other), do: other

  # A literal list can be improper (`[prefix | "  "]` in Logger.Translator):
  # its tail is kept as it is, stripped, rather than mapped as elements.
  defp strip_elements([]), do: []

  defp strip_elements([head | tail]) when is_list(tail),
    do: [strip_location(head) | strip_elements(tail)]

  defp strip_elements([head | tail]), do: [strip_location(head) | strip_location(tail)]

  defp location_keyword?(list) do
    Keyword.keyword?(list) and Keyword.has_key?(list, :file) and Keyword.has_key?(list, :line)
  end

  # What an apply calls is in the registers reaching it
  # (`Argus.Pipeline.Emit.Applies`).
  defp emit_applies(facts, func_id, normalized) do
    func_id
    |> Applies.rows(normalized)
    |> Enum.reduce(facts, &add_fact(&2, :resolved_apply, &1))
  end

  # A fun value is an edge only if the function does not call its target
  # anyway, which only the whole function can say
  # (`Argus.Pipeline.Emit.FunRefs`).
  defp emit_fun_refs(facts, func_id, normalized) do
    facts =
      func_id
      |> FunRefs.rows(normalized)
      |> Enum.reduce(facts, &add_fact(&2, :fun_ref, &1))

    func_id
    |> FunRefs.handed_rows(normalized)
    |> Enum.reduce(facts, &add_fact(&2, :fun_handed, &1))
  end

  # What a spawn runs is in its arguments, so it is resolved here, where
  # the whole function is in hand (`Argus.Pipeline.Emit.Spawns`).
  defp emit_spawns(facts, func_id, normalized) do
    func_id
    |> Spawns.rows(normalized)
    |> Enum.reduce(facts, &add_fact(&2, :spawn_call, &1))
  end

  # apply/2,3 is a call whose target is computed, so the call graph cannot
  # follow it — the same gap as the `apply` and `call_fun` INSTRUCTIONS, but
  # reached as an ordinary remote call to :erlang.apply. Recorded in the
  # same relation so anything reasoning about unfollowable control sees one
  # concept rather than two.
  #
  # Not an effect: apply itself observes nothing. What it reaches might, and
  # that is precisely what cannot be determined.
  defp maybe_dynamic(facts, id, func_id, :erlang, :apply) do
    add_fact(facts, :dynamic_call, [id, func_id, "apply"])
  end

  defp maybe_dynamic(facts, _id, _func_id, _mod, _func), do: facts
end
