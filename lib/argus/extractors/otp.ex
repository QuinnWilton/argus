defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations, process links, and the
  init/handle_continue handshake from module attributes and bytecode.
  The call facts (`sync_call`, `async_cast`, `sup_call`) come from
  `Argus.Extractors.ApiCalls`.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `process_link(from_mod, to_mod)` — Process.link / :erlang.link call
  - `init_continues_to(mod, tag)` — module's init/1 returns `{:continue, tag}`
  - `handle_continue_clause(mod, tag, func_id)` — handle_continue/2 clause matching `tag`
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      get_behaviours: 1,
      match_remote_call: 1,
      resolve_callee: 1,
      return_shapes: 1,
      track_dynamic: 5
    ]

  @impl true
  def relations,
    do: [
      :handle_continue_clause,
      :implements_behaviour,
      :init_continues_to,
      :process_link
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    functions = module_data.functions

    %{}
    |> extract_behaviours(mod_str, module_data.attributes)
    |> extract_link_calls(mod_str, module_data)
    |> extract_continue_facts(mod, mod_str, functions)
  end

  # Two facts:
  #   - init_continues_to(mod, tag) when init/1 returns {:ok, _, {:continue, tag}}
  #   - handle_continue_clause(mod, tag, func_id) for each handle_continue/2 clause
  defp extract_continue_facts(facts, mod, mod_str, functions) do
    facts
    |> extract_init_continues(mod, mod_str, functions)
    |> extract_handle_continue_clauses(mod, mod_str, functions)
  end

  defp extract_init_continues(facts, _mod, mod_str, functions) do
    case Helpers.find_function(functions, :init, 1) do
      nil ->
        facts

      instrs ->
        # Two shapes are common in real BEAM bytecode:
        #   1. The whole return is a literal: `move {literal, {:ok, _, {:continue, tag}}}, x0`.
        #      The compiler folds the entire term when the state is also a literal.
        #   2. The return is built at runtime via `put_tuple2`. The third element
        #      is either a literal `{:continue, tag}` or another `put_tuple2`.
        instrs
        |> return_shapes()
        |> Enum.flat_map(fn {_idx, elements} -> List.wrap(continue_tag(elements)) end)
        |> Enum.uniq()
        |> Enum.reduce(facts, fn tag, acc ->
          add_fact(acc, :init_continues_to, [mod_str, tag])
        end)
    end
  end

  # Look for {:ok, _state, {:continue, tag}} or {:noreply, _state, {:continue, tag}}
  # shapes in a put_tuple2 element list.
  defp continue_tag([{:atom, :ok}, _state, third]), do: extract_continue_from_element(third)

  defp continue_tag([{:atom, :noreply}, _state, third]),
    do: extract_continue_from_element(third)

  defp continue_tag(_), do: nil

  defp extract_continue_from_element({:literal, {:continue, tag}}) when is_atom(tag),
    do: inspect(tag)

  defp extract_continue_from_element(_), do: nil

  # For handle_continue clauses, identify them by name + arity.
  defp extract_handle_continue_clauses(facts, _mod, mod_str, functions) do
    Enum.reduce(functions, facts, fn
      {:function, :handle_continue, 2, _entry, instrs}, acc ->
        func_id = "#{mod_str}:handle_continue/2"

        # The clause head dispatches on the first argument (the tag). We
        # can't easily separate clauses without more analysis, but we can
        # detect tag literals from the test instructions at the top.
        tags = clause_tags(instrs)

        if tags == [] do
          add_fact(acc, :handle_continue_clause, [mod_str, "dynamic", func_id])
        else
          Enum.reduce(tags, acc, fn tag, inner ->
            add_fact(inner, :handle_continue_clause, [mod_str, tag, func_id])
          end)
        end

      _, acc ->
        acc
    end)
  end

  # Find tag literals matched by `is_eq_exact` or `select_val` against x0
  # at the top of handle_continue/2.
  # Only the dispatch prologue, not the whole function.
  #
  # The tag arrives in {x,0}, but {x,0} is also the BEAM's first scratch
  # register, so once a clause body starts it holds whatever that body is
  # working on. Scanning the entire function therefore collected every atom
  # any clause happened to compare against — `:ok`, `nil` and `false` were
  # recorded as handle_continue tags across the corpus, roughly half the
  # rows in the relation.
  #
  # It was quiet because a spurious tag matches nothing downstream and
  # produces silence rather than an error, and because `deferred_startup_
  # deadlock`, the only consumer, reports zero on these projects either way.
  #
  # Stopping at the first write to {x,0} is exact: up to that point the
  # register still holds the tag, and after it never does. Calls count as
  # writes, since they return into {x,0}.
  defp clause_tags(instrs) do
    instrs
    |> Enum.reduce_while([], fn instr, acc ->
      if writes_x0?(instr), do: {:halt, acc}, else: {:cont, acc ++ dispatch_tags(instr)}
    end)
    |> Enum.uniq()
  end

  defp dispatch_tags({:test, :is_eq_exact, _, [{:x, 0}, {:atom, tag}]}) when is_atom(tag),
    do: [inspect(tag)]

  defp dispatch_tags({:select_val, {:x, 0}, _fail, {:list, pairs}}) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:atom, tag}, _label] when is_atom(tag) -> [inspect(tag)]
      _ -> []
    end)
  end

  defp dispatch_tags(_instr), do: []

  defp writes_x0?({:move, _src, {:x, 0}}), do: true
  defp writes_x0?({:get_tuple_element, _src, _idx, {:x, 0}}), do: true
  defp writes_x0?({:put_tuple2, {:x, 0}, _}), do: true
  defp writes_x0?({:put_tuple, _size, {:x, 0}}), do: true
  defp writes_x0?({:put_map_assoc, _f, _src, {:x, 0}, _live, _list}), do: true
  defp writes_x0?({:bif, _name, _f, _args, {:x, 0}}), do: true
  defp writes_x0?({:gc_bif, _name, _f, _live, _args, {:x, 0}}), do: true
  defp writes_x0?(instr), do: match_remote_call(instr) != :none or local_call?(instr)

  defp local_call?({:call, _a, _mfa}), do: true
  defp local_call?({:call_only, _a, _mfa}), do: true
  defp local_call?({:call_last, _a, _mfa, _d}), do: true
  defp local_call?(_instr), do: false

  defp extract_behaviours(facts, mod_str, attrs) do
    attrs
    |> get_behaviours()
    |> Enum.reduce(facts, fn behaviour, acc ->
      add_fact(acc, :implements_behaviour, [mod_str, inspect(behaviour)])
    end)
  end

  defp extract_link_calls(facts, mod_str, module_data) do
    each_remote_call(module_data, facts, fn acc, ctx, mfa ->
      handle_link(acc, mod_str, ctx, mfa)
    end)
  end

  defp handle_link(facts, mod_str, ctx, {Process, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, mod_str, ctx, {:erlang, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, _mod_str, _ctx, _mfa), do: facts

  # Resolve a timeout argument to its string representation for facts.
  # Positive integer → milliseconds, :infinity → "-1", anything else → "0" (dynamic).
end
