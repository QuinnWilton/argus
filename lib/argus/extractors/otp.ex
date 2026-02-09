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

    facts
  end

  defp extract_behaviours(facts, mod_str, attrs) do
    behaviours =
      Keyword.get_values(attrs, :behaviour) ++
        Keyword.get_values(attrs, :behavior)

    behaviours
    |> List.flatten()
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
  # GenServer.call(server, request) compiles to a call_ext to GenServer.call/2 or /3.
  # The server argument is typically in x0 just before the call.
  # We look for a move of an atom/literal into x0 followed by a GenServer call.
  defp scan_for_genserver_calls(facts, func_id, instrs) do
    instrs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(facts, fn
      [_prev, {:call_ext, _arity, {:extfunc, GenServer, :call, arity}}], acc
      when arity in [2, 3] ->
        # Look back for the module being called — we'd need the preceding move.
        # For now, emit with the caller func only. The callee would require
        # more sophisticated dataflow analysis.
        add_fact(acc, :sync_call, [func_id, "dynamic"])

      [_prev, {:call_ext, _arity, {:extfunc, GenServer, :cast, 2}}], acc ->
        add_fact(acc, :async_cast, [func_id, "dynamic"])

      [_prev, {:call_ext_only, _arity, {:extfunc, GenServer, :call, arity}}], acc
      when arity in [2, 3] ->
        add_fact(acc, :sync_call, [func_id, "dynamic"])

      [_prev, {:call_ext_only, _arity, {:extfunc, GenServer, :cast, 2}}], acc ->
        add_fact(acc, :async_cast, [func_id, "dynamic"])

      [_prev, {:call_ext_last, _arity, {:extfunc, GenServer, :call, arity}, _}], acc
      when arity in [2, 3] ->
        add_fact(acc, :sync_call, [func_id, "dynamic"])

      [_prev, {:call_ext_last, _arity, {:extfunc, GenServer, :cast, 2}, _}], acc ->
        add_fact(acc, :async_cast, [func_id, "dynamic"])

      _, acc ->
        acc
    end)
  end

  defp add_fact(facts, relation, row) do
    Map.update(facts, relation, [row], &[row | &1])
  end
end
