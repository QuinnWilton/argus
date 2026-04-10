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

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      instructions_from_label: 2,
      match_remote_call: 1,
      resolve_atom: 3,
      resolve_register: 3,
      scan_functions: 4
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
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)

    scan_functions(mod, module_data.functions, %{}, fn facts, ctx, instr ->
      facts
      |> maybe_bare_rescue(ctx, instr)
      |> maybe_error_handling_call(mod_str, ctx, instr)
    end)
  end

  # The BEAM try instruction is {:try, register, {:f, handler_label}}.
  # After the handler label, {:try_case, register} begins the catch handler.
  defp maybe_bare_rescue(facts, ctx, {:try, _reg, {:f, handler_label}}) do
    if bare_handler?(ctx.instrs, handler_label) do
      id = "#{ctx.func_id}##{ctx.idx}"
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

        instr ->
          case match_remote_call(instr) do
            {:ok, :erlang, :raise, 3} -> true
            {:ok, :erlang, :error, _} -> true
            _ -> false
          end
      end)

    # It's a bare rescue if neither filtering nor reraising is present.
    not has_filter? and not has_reraise? and length(handler_body) > 0
  end

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
  defp maybe_error_handling_call(facts, mod_str, ctx, instr) do
    case match_remote_call(instr) do
      {:ok, Process, :flag, 2} -> maybe_trap_exit(facts, ctx, mod_str)
      {:ok, :erlang, :process_flag, 2} -> maybe_trap_exit(facts, ctx, mod_str)
      {:ok, Process, :exit, 2} -> emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))
      {:ok, :erlang, :exit, 1} -> emit_exit_call(facts, ctx, "self")
      {:ok, :erlang, :exit, 2} -> emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))
      {:ok, mod, func, arity} -> maybe_ignored_result(facts, ctx, mod, func, arity)
      :none -> facts
    end
  end

  defp emit_exit_call(facts, ctx, target) do
    id = "#{ctx.func_id}##{ctx.idx}"
    add_fact(facts, :exit_call, [id, ctx.func_id, target])
  end

  defp maybe_trap_exit(facts, ctx, mod_str) do
    with {:ok, :trap_exit} <- resolve_register(ctx.instrs, ctx.idx, {:x, 0}),
         {:ok, true} <- resolve_register(ctx.instrs, ctx.idx, {:x, 1}) do
      add_fact(facts, :trap_exit, [ctx.func_id, mod_str])
    else
      _ -> facts
    end
  end

  # Check if the result of a call is ignored — if the instruction after the
  # call does not test/branch on the result register (x0).
  defp maybe_ignored_result(facts, ctx, mod, func, arity) do
    if MapSet.member?(@ok_error_apis, {mod, func, arity}) and
         result_ignored?(Enum.drop(ctx.instrs, ctx.idx + 1)) do
      id = "#{ctx.func_id}##{ctx.idx}"
      callee = "#{inspect(mod)}.#{func}/#{arity}"
      add_fact(facts, :ignored_error_result, [id, ctx.func_id, callee])
    else
      facts
    end
  end

  # Result is overwritten before being read — ignored.
  defp result_ignored?([{:move, _, {:x, 0}} | _]), do: true
  defp result_ignored?([{:move, _, {:tr, {:x, 0}, _}} | _]), do: true
  # Anything else is conservatively considered "used".
  defp result_ignored?(_), do: false
end
