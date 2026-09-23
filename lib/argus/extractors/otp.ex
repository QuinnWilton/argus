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
  alias Argus.Instr

  import Argus.Extractor.Helpers, only: [each_remote_call: 3, get_behaviours: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5]
  import Argus.Extractor.Resolve, only: [arg_position: 3, resolve_callee: 1]
  import Argus.Extractor.Shapes, only: [return_shapes: 1]

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

  # The tag literals handle_continue/2 dispatches on: the atoms an
  # `is_eq_exact` or `select_val` compares its first argument against.
  #
  # The tag arrives in {x,0}, but {x,0} is also the BEAM's first scratch
  # register, so once a clause body starts it holds whatever that body is
  # working on. Collecting every comparison on {x,0} recorded every atom
  # any clause happened to compare against — `:ok`, `nil` and `false` were
  # recorded as handle_continue tags across the corpus, roughly half the
  # rows in the relation. A comparison counts only where the writes that
  # reach {x,0} are the parameter itself (`Resolve.arg_position/3`), which
  # also finds the tag of a clause whose test follows another clause's
  # body.
  defp clause_tags(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, idx} ->
      case dispatch_tags(instr) do
        [] -> []
        tags -> if arg_position(instrs, idx, {:x, 0}) == {:ok, 0}, do: tags, else: []
      end
    end)
    |> Enum.uniq()
  end

  defp dispatch_tags({:test, :is_eq_exact, _, [reg, {:atom, tag}]}) when is_atom(tag),
    do: if(Instr.register(reg) == {:x, 0}, do: [inspect(tag)], else: [])

  defp dispatch_tags({:select_val, reg, _fail, {:list, pairs}}) do
    if Instr.register(reg) == {:x, 0} do
      pairs
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [{:atom, tag}, _label] when is_atom(tag) -> [inspect(tag)]
        _ -> []
      end)
    else
      []
    end
  end

  defp dispatch_tags(_instr), do: []

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
