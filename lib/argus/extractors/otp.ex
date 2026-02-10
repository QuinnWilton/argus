defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations and GenServer.call/cast targets
  from module attributes and bytecode patterns.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `sync_call(caller_func, callee_mod)` — GenServer.call target detected
  - `sync_call_timeout(caller_func, callee_mod, timeout_ms)` — timeout value at call site
  - `async_cast(caller_func, callee_mod)` — GenServer.cast target detected
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, get_behaviours: 1, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    attrs = module_data.attributes
    functions = module_data.functions

    facts = %{}

    # Extract behaviour implementations from attributes.
    facts = extract_behaviours(facts, mod_str, attrs)

    # Scan bytecode for GenServer.call/cast patterns.
    facts = extract_genserver_calls(facts, mod, functions)

    # Scan for link/monitor calls.
    extract_link_monitor_calls(facts, mod, functions)
  end

  defp extract_behaviours(facts, mod_str, attrs) do
    attrs
    |> get_behaviours()
    |> Enum.reduce(facts, fn behaviour, acc ->
      add_fact(acc, :implements_behaviour, [mod_str, inspect(behaviour)])
    end)
  end

  defp extract_genserver_calls(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_for_genserver_calls(acc, func_id, instrs)
    end)
  end

  # Scan instructions for sync/async call patterns across GenServer, Agent,
  # and Erlang-style :gen_server.
  defp scan_for_genserver_calls(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        # GenServer.call/2 — default 5000ms timeout.
        {:ok, GenServer, :call, 2} ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "5000"])

        # GenServer.call/3 — explicit timeout in x2.
        {:ok, GenServer, :call, 3} ->
          callee = resolve_callee(instrs, idx)
          timeout = resolve_timeout(instrs, idx, {:x, 2})

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, timeout])

        # GenServer.cast/2.
        {:ok, GenServer, :cast, 2} ->
          callee = resolve_callee(instrs, idx)
          add_fact(acc, :async_cast, [func_id, callee])

        # GenServer.multi_call/2,3,4 — synchronous multi-node call, infinity default.
        {:ok, GenServer, :multi_call, arity} when arity in [2, 3, 4] ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "-1"])

        # Erlang-style :gen_server.call/2 — default 5000ms timeout.
        {:ok, :gen_server, :call, 2} ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "5000"])

        # Erlang-style :gen_server.call/3 — explicit timeout in x2.
        {:ok, :gen_server, :call, 3} ->
          callee = resolve_callee(instrs, idx)
          timeout = resolve_timeout(instrs, idx, {:x, 2})

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, timeout])

        # Erlang-style :gen_server.cast/2.
        {:ok, :gen_server, :cast, 2} ->
          callee = resolve_callee(instrs, idx)
          add_fact(acc, :async_cast, [func_id, callee])

        # Agent.get/2 — default 5000ms timeout.
        {:ok, Agent, :get, 2} ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "5000"])

        # Agent.get/3 — explicit timeout in x2.
        {:ok, Agent, :get, 3} ->
          callee = resolve_callee(instrs, idx)
          timeout = resolve_timeout(instrs, idx, {:x, 2})

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, timeout])

        # Agent.update/2 — default 5000ms timeout.
        {:ok, Agent, :update, 2} ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "5000"])

        # Agent.update/3 — explicit timeout in x2.
        {:ok, Agent, :update, 3} ->
          callee = resolve_callee(instrs, idx)
          timeout = resolve_timeout(instrs, idx, {:x, 2})

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, timeout])

        # Agent.get_and_update/2 — default 5000ms timeout.
        {:ok, Agent, :get_and_update, 2} ->
          callee = resolve_callee(instrs, idx)

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, "5000"])

        # Agent.get_and_update/3 — explicit timeout in x2.
        {:ok, Agent, :get_and_update, 3} ->
          callee = resolve_callee(instrs, idx)
          timeout = resolve_timeout(instrs, idx, {:x, 2})

          acc
          |> add_fact(:sync_call, [func_id, callee])
          |> add_fact(:sync_call_timeout, [func_id, callee, timeout])

        _ ->
          acc
      end
    end)
  end

  # Scan instructions for Process.link/1, :erlang.link/1, Process.monitor/1,2,
  # :erlang.monitor/2. Emit process_link and process_monitor facts.
  defp extract_link_monitor_calls(facts, mod, functions) do
    mod_str = inspect(mod)

    Enum.reduce(functions, facts, fn {:function, _name, _arity, _entry, instrs}, acc ->
      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {instr, idx}, inner_acc ->
        case match_remote_call(instr) do
          {:ok, Process, :link, 1} ->
            target = resolve_callee(instrs, idx)
            add_fact(inner_acc, :process_link, [mod_str, target])

          {:ok, :erlang, :link, 1} ->
            target = resolve_callee(instrs, idx)
            add_fact(inner_acc, :process_link, [mod_str, target])

          {:ok, Process, :monitor, arity} when arity in [1, 2] ->
            target = resolve_callee(instrs, idx)
            add_fact(inner_acc, :process_monitor, [mod_str, target])

          {:ok, :erlang, :monitor, 2} ->
            # x0 is the monitor type (:process), x1 is the target.
            target =
              case resolve_register(instrs, idx, {:x, 1}) do
                {:ok, atom} when is_atom(atom) -> inspect(atom)
                _ -> "dynamic"
              end

            add_fact(inner_acc, :process_monitor, [mod_str, target])

          _ ->
            inner_acc
        end
      end)
    end)
  end

  # Resolve the GenServer target from x0 at the call site.
  defp resolve_callee(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end

  # Resolve a timeout argument to its string representation for facts.
  # Positive integer → milliseconds, :infinity → "-1", anything else → "0" (dynamic).
  defp resolve_timeout(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, n} when is_integer(n) and n > 0 -> to_string(n)
      {:ok, :infinity} -> "-1"
      _ -> "0"
    end
  end
end
