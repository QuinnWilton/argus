defmodule Argus.Extractors.ErrorHandling do
  @moduledoc """
  Error handling extractor.

  Detects error handling patterns and anti-patterns in BEAM bytecode:
  bare rescues (catch-all without filtering or reraising), trap_exit
  without handlers, explicit exit calls, and ignored error results.

  ## Approach

  For bare rescue detection, walks forward from `try_start` handler labels.
  If the handler code contains no `test`/`select_val` filtering exception
  class and no `:erlang.raise/3` call, it's a bare rescue that silently
  swallows exceptions.

  ## Emitted facts

  - `bare_rescue(id, func)` — catch-all rescue without filtering or reraising
  - `trap_exit(func, mod)` — `Process.flag(:trap_exit, true)` call site
  - `exit_call(id, func, target)` — explicit `Process.exit/2` or `:erlang.exit/1,2`
  - `ignored_error_result(id, func, callee)` — call to known ok/error API where
    result is not pattern matched
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      instructions_from_label: 2,
      match_remote_call: 1,
      resolve_atom: 3,
      resolve_register: 3,
      scan_functions: 4,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  # Functions known to return {:ok, _} | {:error, _} whose result should
  # be checked. Only widely-used stdlib functions are included.
  @ok_error_apis MapSet.new([
                   {GenServer, :start_link, 2},
                   {GenServer, :start_link, 3},
                   {GenServer, :start, 2},
                   {GenServer, :start, 3},
                   {GenServer, :stop, 1},
                   {GenServer, :stop, 3},
                   {Supervisor, :start_link, 2},
                   {Supervisor, :start_link, 3},
                   {Agent, :start_link, 1},
                   {Agent, :start_link, 2},
                   {Agent, :start, 1},
                   {Agent, :start, 2},
                   {File, :open, 1},
                   {File, :open, 2},
                   {File, :read, 1},
                   {File, :write, 2},
                   {File, :write, 3},
                   {:gen_server, :start_link, 3},
                   {:gen_server, :start_link, 4},
                   {:gen_server, :start, 3},
                   {:gen_server, :start, 4},
                   {:gen_tcp, :connect, 3},
                   {:gen_tcp, :connect, 4},
                   {:gen_tcp, :listen, 2},
                   {:gen_udp, :open, 1},
                   {:gen_udp, :open, 2},
                   {:file, :open, 2},
                   {:file, :read_file, 1},
                   {:file, :write_file, 2}
                 ])

  @impl true
  def relations,
    do: [
      :bare_rescue,
      :exit_call,
      :ignored_error_result,
      :trap_exit
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)

    rescues =
      scan_functions(mod, module_data.functions, %{}, fn facts, ctx, instr ->
        maybe_bare_rescue(facts, ctx, instr)
      end)

    each_remote_call(module_data, rescues, fn facts, ctx, mfa ->
      error_handling_call(facts, mod_str, ctx, mfa)
    end)
  end

  # The BEAM try instruction is {:try, register, {:f, handler_label}}.
  # After the handler label, {:try_case, register} begins the catch handler.
  defp maybe_bare_rescue(facts, ctx, {:try, _reg, {:f, handler_label}}) do
    if bare_handler?(ctx.instrs, handler_label) do
      id = InstrId.mint(ctx.func_id, ctx.idx)
      add_fact(facts, :bare_rescue, [id, ctx.func_id])
    else
      facts
    end
  end

  defp maybe_bare_rescue(facts, _ctx, _instr), do: facts

  # Check whether a handler starting at the given label is a bare rescue.
  # A bare rescue catches all exceptions without filtering the exception
  # class and without reraising. The handler starts after {:try_case, _}
  # and extends until the next label, return, or function boundary.
  defp bare_handler?(instrs, handler_label) do
    handler_instrs = instructions_from_label(instrs, handler_label)
    # Skip the label itself and try_case to get to the handler body.
    handler_body = take_handler_body(handler_instrs)

    has_filter? =
      Enum.any?(handler_body, fn
        {:test, _, _, _} -> true
        {:select_val, _, _, _} -> true
        _ -> false
      end)

    has_reraise? =
      Enum.any?(handler_body, fn
        {:bif, :raise, _, _, _} ->
          true

        # Since OTP 21, `:erlang.raise(kind, reason, __STACKTRACE__)` in a
        # catch handler compiles to the standalone `raw_raise` opcode, not
        # a call to :erlang.raise/3 — so a re-raising handler (NimblePool,
        # DBConnection.run) was read as swallowing.
        :raw_raise ->
          true

        {:raw_raise} ->
          true

        instr ->
          case match_remote_call(instr) do
            {:ok, :erlang, :raise, 3} -> true
            {:ok, :erlang, :error, _} -> true
            _ -> false
          end
      end)

    # It's a bare rescue if it neither filters the exception class,
    # reraises, nor reifies the caught exception into a value it returns,
    # logs, or hands to another function.
    not has_filter? and not has_reraise? and not reifies_exception?(handler_body) and
      handler_body != []
  end

  # After `{:try_case, _}` the caught exception occupies x0 (class), x1
  # (reason), and x2 (stacktrace). A handler that reads any of them before
  # overwriting it is doing something with the exception — returning
  # `{:error, reason}`, logging it, passing it to a handler function — not
  # silently swallowing it. A truly-bare handler (`catch _, _ -> :ok` /
  # `-> default`) overwrites x0 with its return value and never reads the
  # exception registers. This is a small liveness scan: start with the
  # three exception registers live, and report a read the moment a live
  # one is used as a source, tracking overwrites so a reused register
  # (the return value later moved through x0) is not mistaken for the
  # exception.
  @exception_regs MapSet.new([{:x, 0}, {:x, 1}, {:x, 2}])

  defp reifies_exception?(handler_body) do
    result =
      Enum.reduce_while(handler_body, @exception_regs, fn instr, live ->
        if Enum.any?(source_regs(instr), &MapSet.member?(live, &1)) do
          {:halt, :reifies}
        else
          {:cont, MapSet.difference(live, MapSet.new(dest_regs(instr)))}
        end
      end)

    result == :reifies
  end

  # Registers read (as source operands) by an instruction. Only the shapes
  # that can appear in a catch handler and can carry an exception register
  # are enumerated; anything else reads nothing relevant. A call of arity N
  # reads x0..x(N-1) (its argument registers).
  defp source_regs({:move, src, _dst}), do: regs([src])
  defp source_regs({:swap, a, b}), do: regs([a, b])
  defp source_regs({:put_list, hd, tl, _dst}), do: regs([hd, tl])
  defp source_regs({:put_tuple2, _dst, {:list, elems}}), do: regs(elems)
  defp source_regs({:get_tuple_element, src, _idx, _dst}), do: regs([src])
  defp source_regs({:get_hd, src, _dst}), do: regs([src])
  defp source_regs({:get_tl, src, _dst}), do: regs([src])
  defp source_regs({:call, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_only, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_last, arity, _, _}), do: arg_regs(arity)
  defp source_regs({:call_ext, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_ext_only, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_ext_last, arity, _, _}), do: arg_regs(arity)
  defp source_regs({:bif, _name, _fail, args, _dst}) when is_list(args), do: regs(args)
  defp source_regs({:gc_bif, _name, _fail, _live, args, _dst}) when is_list(args), do: regs(args)
  defp source_regs({:test, _op, _fail, args}) when is_list(args), do: regs(args)
  # raw_raise / build_stacktrace operate on the caught exception in place.
  defp source_regs(:raw_raise), do: [{:x, 0}]
  defp source_regs({:raw_raise}), do: [{:x, 0}]
  defp source_regs(:build_stacktrace), do: [{:x, 0}]
  defp source_regs({:build_stacktrace}), do: [{:x, 0}]
  defp source_regs(_instr), do: []

  # Registers written (as destination) by an instruction — removed from the
  # live exception set so a later reuse of the register is not mistaken for
  # a read of the exception. A call writes its result to x0.
  defp dest_regs({:move, _src, dst}), do: regs([dst])
  defp dest_regs({:swap, a, b}), do: regs([a, b])
  defp dest_regs({:put_list, _hd, _tl, dst}), do: regs([dst])
  defp dest_regs({:put_tuple2, dst, _}), do: regs([dst])
  defp dest_regs({:get_tuple_element, _src, _idx, dst}), do: regs([dst])
  defp dest_regs({:get_hd, _src, dst}), do: regs([dst])
  defp dest_regs({:get_tl, _src, dst}), do: regs([dst])
  defp dest_regs({:call, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_only, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_last, _, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext_only, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext_last, _, _, _}), do: [{:x, 0}]
  defp dest_regs({:bif, _name, _fail, _args, dst}), do: regs([dst])
  defp dest_regs({:gc_bif, _name, _fail, _live, _args, dst}), do: regs([dst])
  defp dest_regs(_instr), do: []

  # Normalize operands to plain registers, dropping literals/atoms/labels.
  defp regs(operands), do: operands |> Enum.map(&to_reg/1) |> Enum.reject(&is_nil/1)

  defp to_reg({:x, _} = reg), do: reg
  defp to_reg({:y, _} = reg), do: reg
  defp to_reg({:tr, inner, _type}), do: to_reg(inner)
  defp to_reg(_operand), do: nil

  defp arg_regs(arity) when arity > 0, do: for(i <- 0..(arity - 1), do: {:x, i})
  defp arg_regs(_arity), do: []

  # Extract handler body: skip labels and try_case, take until next
  # label, try, func_info, or function boundary.
  defp take_handler_body([]), do: []
  defp take_handler_body([{:label, _} | rest]), do: take_handler_body(rest)
  defp take_handler_body([{:try_case, _} | rest]), do: take_handler_body(rest)

  defp take_handler_body(instrs) do
    Enum.take_while(instrs, fn
      {:label, _} -> false
      {:try, _, _} -> false
      {:try_end, _} -> false
      {:try_case, _} -> false
      {:func_info, _, _, _} -> false
      _ -> true
    end)
  end

  # Handle remote calls relevant to error-handling: trap_exit, exit calls,
  # and ignored error results from known {ok, _} | {error, _} APIs.
  defp error_handling_call(facts, mod_str, ctx, mfa) do
    case mfa do
      {Process, :flag, 2} ->
        maybe_trap_exit(facts, ctx, mod_str)

      {:erlang, :process_flag, 2} ->
        maybe_trap_exit(facts, ctx, mod_str)

      {Process, :exit, 2} ->
        emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))

      {:erlang, :exit, 1} ->
        emit_exit_call(facts, ctx, "self")

      {:erlang, :exit, 2} ->
        emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))

      {mod, func, arity} ->
        maybe_ignored_result(facts, ctx, mod, func, arity)
    end
  end

  defp emit_exit_call(facts, ctx, target) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    facts
    |> track_dynamic(target, ctx, :exit_call_target, :exit_call)
    |> add_fact(:exit_call, [id, ctx.func_id, target])
  end

  defp maybe_trap_exit(facts, ctx, mod_str) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, :trap_exit} ->
        case resolve_register(ctx.instrs, ctx.idx, {:x, 1}) do
          {:ok, true} ->
            add_fact(facts, :trap_exit, [ctx.func_id, mod_str])

          {:ok, false} ->
            # Explicit Process.flag(:trap_exit, false) — not imprecision.
            facts

          _ ->
            track_imprecision(facts, ctx, :trap_exit_unresolved, :trap_exit, :skipped)
        end

      _ ->
        # Not a trap_exit call (e.g. Process.flag(:priority, :high)).
        facts
    end
  end

  # Check if the result of a call is ignored — if the instruction after the
  # call does not test/branch on the result register (x0).
  #
  # Four outcomes:
  # 1. Tail call (call_ext_only / call_ext_last) — result IS the function's
  #    return value, so it's definitively used. No fact, no imprecision.
  # 2. Non-tail call where the next instruction overwrites x0 — result IS
  #    ignored. Emit ignored_error_result fact.
  # 3. Non-tail call where the next instruction reads/tests/saves x0 —
  #    result IS actively used. No fact, no imprecision.
  # 4. None of the above — the heuristic gives up. Emit imprecision event.
  defp maybe_ignored_result(facts, ctx, mod, func, arity) do
    if MapSet.member?(@ok_error_apis, {mod, func, arity}) do
      instr = Enum.at(ctx.instrs, ctx.idx)
      after_call = Enum.drop(ctx.instrs, ctx.idx + 1)

      cond do
        # Tail calls return their result to the caller — not ignored.
        tail_call?(instr) ->
          facts

        # Non-tail call where x0 is immediately overwritten.
        result_ignored?(after_call) ->
          id = InstrId.mint(ctx.func_id, ctx.idx)
          callee = "#{inspect(mod)}.#{func}/#{arity}"
          add_fact(facts, :ignored_error_result, [id, ctx.func_id, callee])

        # Non-tail call where x0 is actively consumed (saved, tested,
        # destructured, or branched on).
        result_used?(after_call) ->
          facts

        # Can't determine the result's fate.
        true ->
          track_imprecision(
            facts,
            ctx,
            :ignored_result_unknown_api,
            :ignored_error_result,
            :skipped
          )
      end
    else
      facts
    end
  end

  # Tail call variants — the function returns whatever the callee returns.
  defp tail_call?({:call_ext_only, _, _}), do: true
  defp tail_call?({:call_ext_last, _, _, _}), do: true
  defp tail_call?(_), do: false

  # Result is overwritten before being read — ignored.
  defp result_ignored?([{:move, _, {:x, 0}} | _]), do: true
  defp result_ignored?([{:move, _, {:tr, {:x, 0}, _}} | _]), do: true
  defp result_ignored?(_), do: false

  # Result is actively consumed by the next instruction — used.
  # Saved to a y-register (stack) for use across subsequent calls.
  defp result_used?([{:move, {:x, 0}, {:y, _}} | _]), do: true
  defp result_used?([{:move, {:tr, {:x, 0}, _}, {:y, _}} | _]), do: true
  defp result_used?([{:move, {:x, 0}, {:tr, {:y, _}, _}} | _]), do: true
  # Pattern matching / branching on x0.
  defp result_used?([{:test, _, _, [{:x, 0} | _]} | _]), do: true
  defp result_used?([{:test, _, _, [_, {:x, 0}]} | _]), do: true
  defp result_used?([{:test, _, _, [{:tr, {:x, 0}, _} | _]} | _]), do: true
  defp result_used?([{:select_val, {:x, 0}, _, _} | _]), do: true
  # Tuple destructuring of x0 (e.g. {:ok, value} = call()).
  defp result_used?([{:get_tuple_element, {:x, 0}, _, _} | _]), do: true
  defp result_used?([{:get_tuple_element, {:tr, {:x, 0}, _}, _, _} | _]), do: true
  # x0 used as argument to the next call (passed forward).
  defp result_used?([{:call_ext, _, _} | _]), do: true
  defp result_used?([{:call, _, _} | _]), do: true
  defp result_used?(_), do: false
end
