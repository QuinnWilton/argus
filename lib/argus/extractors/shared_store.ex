defmodule Argus.Extractors.SharedStore do
  @moduledoc """
  Shared cache operations and identities used by the replay-claim analysis.

  ConCache's individual reads and writes do not reserve a key. Its `isolated/3`
  callback does, but only for the cache and key passed to that call. Unary leaf
  helpers containing only known pure calls retain an expression identity, so
  independently computing the same normalized key still names the same row.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Identity
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize
  alias Argus.Purity.Effects

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations,
    do: [
      :shared_store_op,
      :shared_store_argument,
      :shared_store_transform,
      :shared_store_lock,
      :shared_store_callback,
      :shared_store_gate,
      :shared_store_return_choice,
      :shared_store_returned_call
    ]

  @doc "Whether the call is a modeled shared-cache operation."
  @spec site?(mfa()) :: boolean()
  def site?({ConCache, :get, 2}), do: true
  def site?({ConCache, :put, 3}), do: true
  def site?(_mfa), do: false

  @impl true
  def extract(module_data) do
    origins = Identity.origins_index(module_data)
    transforms = transforms(module_data)

    facts =
      module_data
      |> CallSites.for_module()
      |> Enum.reduce(%{}, fn ctx, facts ->
        ctx = Map.merge(ctx, %{origins: {origins, ctx.func_id}, transforms: transforms})

        facts
        |> operation(ctx)
        |> arguments(ctx)
        |> callback(ctx)
        |> lock(ctx)
      end)

    facts
    |> choices(module_data)
    |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
  end

  # An equality branch protects precisely the later operation it dominates.
  # Capture literal return choices as well so wrappers translating nil to
  # :not_found and then :ok retain which result actually means absence.
  defp choices(facts, module_data) do
    Enum.reduce(module_data.functions, facts, fn {:function, name, arity, _, instrs}, acc ->
      func = Normalize.func_id(module_data.module, name, arity)
      cfg = Helpers.cfg(module_data, name, arity)
      guards = equality_guards(instrs)

      Enum.reduce(Enum.with_index(instrs), acc, fn {instruction, at}, found ->
        found = returned_call(found, instruction, instrs, at, func)

        Enum.reduce(guards, found, fn {branch, edge, source_at, literal}, guarded ->
          with true <- SecurityValues.edge_covers?(cfg, branch, edge, at),
               {kind, source} <- result_source(instrs, source_at, func) do
            emit_choice(guarded, instruction, instrs, at, func, kind, source, literal)
          else
            _ -> guarded
          end
        end)
      end)
    end)
  end

  defp emit_choice(facts, :return, instrs, at, func, kind, source, literal) do
    case SecurityValues.identity_at(instrs, at, {:x, 0}) do
      {:literal, value} when is_atom(value) ->
        add_fact(facts, :shared_store_return_choice, [
          func,
          kind,
          source,
          Terms.spell(literal),
          Terms.spell(value)
        ])

      {:call, source_at} ->
        if result_source(instrs, source_at, func) == {kind, source} do
          add_fact(facts, :shared_store_return_choice, [
            func,
            kind,
            source,
            Terms.spell(literal),
            Terms.spell(literal)
          ])
        else
          facts
        end

      _ ->
        facts
    end
  end

  defp emit_choice(facts, instruction, _instrs, at, func, kind, source, literal) do
    if Instr.call?(instruction) or Instr.tail_call?(instruction) do
      add_fact(facts, :shared_store_gate, [
        InstrId.mint(func, at),
        func,
        kind,
        source,
        Terms.spell(literal)
      ])
    else
      facts
    end
  end

  # Return data provenance includes copied fields and transformed values. Only
  # an unchanged call result can pass its absence sentinel through a wrapper.
  defp returned_call(facts, instruction, instrs, at, func) do
    source_at =
      cond do
        Instr.tail_call?(instruction) ->
          at

        instruction == :return ->
          case SecurityValues.identity_at(instrs, at, {:x, 0}) do
            {:call, source_at} -> source_at
            _ -> nil
          end

        true ->
          nil
      end

    with source_at when is_integer(source_at) <- source_at,
         false <- tested_result?(instrs, source_at),
         {kind, source} <- result_source(instrs, source_at, func) do
      add_fact(facts, :shared_store_returned_call, [func, kind, source])
    else
      _ -> facts
    end
  end

  # A wrapper returning the original value only on its non-nil branch does not
  # forward nil. Branch-selected equal literals are emitted separately above.
  defp tested_result?(instrs, source_at) do
    Enum.any?(Enum.with_index(instrs), fn {instruction, at} ->
      op = if is_tuple(instruction), do: elem(instruction, 0), else: instruction

      op in [:test, :select_val, :select_tuple_arity] and
        Enum.any?(Instr.uses(instruction), fn reg ->
          SecurityValues.identity_at(instrs, at, reg) == {:call, source_at}
        end)
    end)
  end

  defp equality_guards(instrs) do
    for {{:test, op, _, [left, right]}, at} <- Enum.with_index(instrs),
        op in [:is_eq_exact, :is_ne_exact],
        pair <- [
          {SecurityValues.identity_at(instrs, at, left),
           SecurityValues.identity_at(instrs, at, right)},
          {SecurityValues.identity_at(instrs, at, right),
           SecurityValues.identity_at(instrs, at, left)}
        ],
        {{:call, source_at}, {:literal, value}} <- [pair],
        is_atom(value),
        do: {at, if(op == :is_eq_exact, do: :branch_pass, else: :branch_fail), source_at, value}
  end

  defp result_source(instrs, at, func) do
    instruction = Enum.at(instrs, at)

    case Helpers.match_remote_call(instruction) do
      {:ok, mod, name, arity} ->
        if site?({mod, name, arity}),
          do: {"site", InstrId.mint(func, at)},
          else: {"call", InstrId.mint(func, at)}

      :none ->
        case Helpers.match_local_call(instruction) do
          {:ok, _mod, _name, _arity} -> {"call", InstrId.mint(func, at)}
          :none -> nil
        end
    end
  end

  defp callback(facts, %{mfa: {ConCache, :isolated, 3}} = ctx) do
    case Resolve.fun_origin(ctx.instrs, ctx.idx, {:x, 2}) do
      {:closure, {mod, fun, arity}} ->
        add_fact(facts, :shared_store_callback, [ctx.func_id, Normalize.func_id(mod, fun, arity)])

      _ ->
        facts
    end
  end

  defp callback(facts, _ctx), do: facts

  defp operation(facts, %{mfa: mfa} = ctx) do
    if site?(mfa) do
      {_, operation, _} = mfa
      {store_transform, store_source, store} = identity(ctx, {:x, 0})
      {key_transform, key_source, key} = identity(ctx, {:x, 1})

      facts
      |> expression(store_transform)
      |> expression(key_transform)
      |> add_fact(:shared_store_op, [
        InstrId.mint(ctx.func_id, ctx.idx),
        ctx.func_id,
        Atom.to_string(operation),
        source(store_transform, store_source),
        store,
        source(key_transform, key_source),
        key
      ])
    else
      facts
    end
  end

  defp arguments(facts, %{mfa: {mod, fun, arity}} = ctx) do
    Enum.reduce(0..(min(arity, 4) - 1)//1, facts, fn pos, acc ->
      {transform, source, value} = identity(ctx, {:x, pos})

      acc
      |> expression(transform)
      |> add_fact(:shared_store_argument, [
        InstrId.mint(ctx.func_id, ctx.idx),
        ctx.func_id,
        Normalize.func_id(mod, fun, arity),
        to_string(pos),
        transform,
        source,
        value
      ])
    end)
  end

  # Record the actual closure argument, and translate the lock identities into its
  # environment parameters. A nearby isolation of another key is not protection.
  defp lock(facts, %{mfa: {ConCache, :isolated, 3}} = ctx) do
    with true <- exclusive_callback?(ctx),
         {:closure, {mod, fun, arity}} <- Resolve.fun_origin(ctx.instrs, ctx.idx, {:x, 2}),
         {at, env} when is_list(env) <- closure_environment(ctx, {mod, fun, arity}),
         {ss, sv} <- exact_key_identity(ctx, ctx.idx, {:x, 0}),
         {ks, kv} <- exact_key_identity(ctx, ctx.idx, {:x, 1}),
         true <- ss != "dynamic" and ks != "dynamic",
         {cs, cv} <- captured_identity(ctx, at, env, arity, {ss, sv}),
         {ck, ckval} <- captured_identity(ctx, at, env, arity, {ks, kv}) do
      add_fact(facts, :shared_store_lock, [Normalize.func_id(mod, fun, arity), cs, cv, ck, ckval])
    else
      _ -> facts
    end
  end

  defp lock(facts, _ctx), do: facts

  # A closure also returned, stored, or called outside this isolation can run
  # without its lock. Copies are fine; every actual use must be this invocation.
  defp exclusive_callback?(ctx) do
    wanted = SecurityValues.identity_at(ctx.instrs, ctx.idx, {:x, 2})

    wanted != nil and
      Enum.all?(Enum.with_index(ctx.instrs), fn {instruction, at} ->
        at == ctx.idx or
          Enum.all?(Instr.uses(instruction), fn register ->
            SecurityValues.identity_at(ctx.instrs, at, register) != wanted or
              Enum.any?(Instr.defs(instruction), fn dst ->
                Instr.copy_source(instruction, dst) == register
              end)
          end)
      end)
  end

  defp closure_environment(ctx, target) do
    Resolve.trace(ctx.instrs, ctx.idx, {:x, 2}, nil, fn
      {at, {:make_fun3, ^target, _, _, _, {:list, env}}}, _follow -> {at, env}
      _, _follow -> nil
    end)
  end

  defp captured_identity(_ctx, _at, _env, _arity, {"literal", _} = identity), do: identity

  defp captured_identity(ctx, at, env, arity, wanted) do
    env
    |> Enum.with_index(arity - length(env))
    |> Enum.find_value(fn {register, pos} ->
      if exact_key_identity(ctx, at, register) == wanted,
        do: {"param", to_string(pos)}
    end)
  end

  defp identity(ctx, register) do
    Resolve.trace(ctx.instrs, ctx.idx, register, nil, fn
      {at, instruction}, _follow ->
        case Helpers.match_local_call(instruction) do
          {:ok, mod, fun, 1} ->
            transform = Normalize.func_id(mod, fun, 1)

            if MapSet.member?(ctx.transforms, transform) do
              {source, value} = exact_key_identity(ctx, at, {:x, 0})
              {transform, source, value}
            end

          _ ->
            nil
        end

      _, _follow ->
        nil
    end) || plain_identity(ctx, register)
  end

  defp plain_identity(ctx, register) do
    {source, value} = exact_key_identity(ctx, ctx.idx, register)
    {"", source, value}
  end

  # Identity's field vocabulary is intentionally coarse for several older
  # analyses. A cache key or resource must retain the containing map here: two
  # options maps with the same :cache field are not one store.
  defp exact_key_identity(ctx, at, register) do
    case Identity.key_identity(ctx.instrs, at, register, ctx.origins) do
      {"field", _} ->
        case SecurityValues.identity_at(ctx.instrs, at, register) do
          nil -> {"dynamic", ""}
          value -> {"local", ctx.func_id <> " value " <> Terms.spell(value)}
        end

      identity ->
        identity
    end
  end

  defp expression(facts, ""), do: facts
  defp expression(facts, transform), do: add_fact(facts, :shared_store_transform, [transform])
  defp source(_transform, "dynamic"), do: "dynamic"
  defp source("", source), do: source
  defp source(transform, source), do: "mapped #{transform} #{source}"

  # Only leaf unary functions: no unknown calls, local calls, dynamic execution,
  # process-specific BIFs, receives or message effects can stand for a stable key.
  defp transforms(module_data) do
    for {:function, name, 1, _entry, instructions} <- module_data.functions,
        Enum.all?(instructions, &stable_instruction?/1),
        into: MapSet.new(),
        do: Normalize.func_id(module_data.module, name, 1)
  end

  defp stable_instruction?(instruction) do
    case Helpers.match_remote_call(instruction) do
      {:ok, mod, fun, arity} ->
        Effects.classify(inspect(mod), Atom.to_string(fun), arity) == :pure

      :none ->
        stable_noncall?(instruction)
    end
  end

  defp stable_noncall?({:bif, fun, _, args, _}), do: pure_bif?(fun, args)
  defp stable_noncall?({:gc_bif, fun, _, _, args, _}), do: pure_bif?(fun, args)

  defp stable_noncall?(instruction) do
    op = if is_tuple(instruction), do: elem(instruction, 0), else: instruction

    Instr.known?(instruction) and not Instr.call?(instruction) and
      not Instr.tail_call?(instruction) and
      op not in [:send, :loop_rec, :wait, :wait_timeout, :remove_message]
  end

  defp pure_bif?(fun, args),
    do: Effects.classify(":erlang", Atom.to_string(fun), length(args)) == :pure
end
