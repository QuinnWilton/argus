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
      resolve_register: 3
    ]

  alias Argus.Normalize

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
    functions = module_data.functions

    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)

      facts
      |> scan_bare_rescues(func_id, instrs)
      |> scan_calls(func_id, mod_str, instrs)
    end)
  end

  # Scan for try instructions and check if handlers are bare rescues.
  # The BEAM try instruction is {:try, register, {:f, handler_label}}.
  # After the handler label, {:try_case, register} begins the catch handler.
  defp scan_bare_rescues(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{:try, _reg, {:f, handler_label}}, idx}, acc ->
        if bare_handler?(instrs, handler_label) do
          id = "#{func_id}##{idx}"
          add_fact(acc, :bare_rescue, [id, func_id])
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

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

  # Scan for trap_exit, exit calls, and ignored error results.
  defp scan_calls(facts, func_id, mod_str, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        # Process.flag(:trap_exit, true).
        {:ok, Process, :flag, 2} ->
          maybe_trap_exit(acc, func_id, mod_str, instrs, idx)

        {:ok, :erlang, :process_flag, 2} ->
          maybe_trap_exit(acc, func_id, mod_str, instrs, idx)

        # Process.exit/2.
        {:ok, Process, :exit, 2} ->
          id = "#{func_id}##{idx}"
          target = resolve_target(instrs, idx)
          add_fact(acc, :exit_call, [id, func_id, target])

        # :erlang.exit/1,2.
        {:ok, :erlang, :exit, arity} when arity in [1, 2] ->
          id = "#{func_id}##{idx}"

          target =
            if arity == 2, do: resolve_target(instrs, idx), else: "self"

          add_fact(acc, :exit_call, [id, func_id, target])

        # Check for ignored error results.
        {:ok, mod, func, arity} ->
          if MapSet.member?(@ok_error_apis, {mod, func, arity}) do
            maybe_ignored_result(acc, func_id, instrs, idx, mod, func, arity)
          else
            acc
          end

        :none ->
          acc
      end
    end)
  end

  defp maybe_trap_exit(facts, func_id, mod_str, instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, :trap_exit} ->
        case resolve_register(instrs, idx, {:x, 1}) do
          {:ok, true} -> add_fact(facts, :trap_exit, [func_id, mod_str])
          _ -> facts
        end

      _ ->
        facts
    end
  end

  defp resolve_target(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end

  # Check if the result of a call is ignored — if the instruction after the
  # call does not test/branch on the result register (x0).
  defp maybe_ignored_result(facts, func_id, instrs, idx, mod, func, arity) do
    following = Enum.drop(instrs, idx + 1)

    ignored? =
      case following do
        # Result immediately overwritten — ignored.
        [{:move, _, {:x, 0}} | _] -> true
        [{:move, _, {:tr, {:x, 0}, _}} | _] -> true
        # Result tested — not ignored.
        [{:test, _, _, _} | _] -> false
        # Result pattern matched via tuple element extraction.
        [{:get_tuple_element, {:x, 0}, _, _} | _] -> false
        [{:get_tuple_element, {:tr, {:x, 0}, _}, _, _} | _] -> false
        # Result moved to another register and likely used.
        [{:move, {:x, 0}, _} | _] -> false
        [{:move, {:tr, {:x, 0}, _}, _} | _] -> false
        # Return immediately — result passed through (not ignored).
        [:return | _] -> false
        # Call or tail call immediately — result passed as argument.
        [{:call_ext, _, _} | _] -> false
        [{:call_ext_only, _, _} | _] -> false
        [{:call_ext_last, _, _, _} | _] -> false
        [{:call, _, _} | _] -> false
        # Branching on result.
        [{:select_val, {:x, 0}, _, _} | _] -> false
        [{:select_val, {:tr, {:x, 0}, _}, _, _} | _] -> false
        # Default: if we can't tell, don't flag it.
        _ -> false
      end

    if ignored? do
      id = "#{func_id}##{idx}"
      callee = "#{inspect(mod)}.#{func}/#{arity}"
      add_fact(facts, :ignored_error_result, [id, func_id, callee])
    else
      facts
    end
  end
end
