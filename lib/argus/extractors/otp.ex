defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations and GenServer.call/cast targets
  from module attributes and bytecode patterns.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `sync_call(caller_func, callee_mod)` — GenServer.call target detected
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
    extract_genserver_calls(facts, mod, functions)
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

  # Scan instructions for GenServer.call/cast patterns.
  # Uses match_remote_call/1 to recognize call variants and resolve_register/3
  # to attempt resolving the server argument (x0).
  defp scan_for_genserver_calls(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, GenServer, :call, arity} when arity in [2, 3] ->
          callee = resolve_callee(instrs, idx)
          add_fact(acc, :sync_call, [func_id, callee])

        {:ok, GenServer, :cast, 2} ->
          callee = resolve_callee(instrs, idx)
          add_fact(acc, :async_cast, [func_id, callee])

        _ ->
          acc
      end
    end)
  end

  # Resolve the GenServer target from x0 at the call site.
  defp resolve_callee(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end
end
