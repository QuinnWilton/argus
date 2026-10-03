defmodule Argus.Extractors.ParamFlow.SequenceBounds do
  @moduledoc """
  Finite character vocabularies at successful list-to-atom calls.

  A sequence keeps an integer-character alphabet separately from its length;
  neither property by itself proves a finite vocabulary. Numeric guards bound
  only the possible integer characters. Other values (including floats) remain
  possible until list_to_atom's successful-input contract excludes them.

  Private parameters and partial tuple returns are solved together from bottom.
  Exported and captured functions start with unknown parameters. Recursive list
  growth widens the maximum length to infinity, preserving its alphabet. No
  answer is published until both the module and each CFG reach a fixed point.
  Unsupported operations lose their results; budget exhaustion loses every proof.
  """

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.SequenceBounds.Value
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.InstrId

  @max_rounds 64
  @max_steps 2_000_000
  @max_functions 256
  @max_states 512

  @doc "Sites whose successful list_to_atom input has at most 1,024 possible names."
  @spec bounded_sites(map(), [map()], keyword()) :: MapSet.t()
  def bounded_sites(data, candidates, opts \\ []) do
    targets = Enum.filter(candidates, &(&1.mfa == {:erlang, :list_to_atom, 1}))
    # Construct the opaque set at the public boundary; the proof returns plain
    # rows so Dialyzer does not expand MapSet's representation across branches.
    rows = if targets == [], do: [], else: bounded(data, targets, opts)
    MapSet.new(rows)
  end

  defp bounded(data, targets, opts) do
    calls = CallSites.for_module(data)
    functions = functions(data, calls, targets)
    rounds = Keyword.get(opts, :max_rounds, @max_rounds)
    steps = Keyword.get(opts, :max_steps, @max_steps)
    limit = Keyword.get(opts, :max_functions, @max_functions)

    if map_size(functions) > limit or
         Enum.any?(functions, fn {_, f} ->
           f.cfg == nil or cyclic?(f.cfg) or
             Enum.any?(f.instrs, &(not Instr.known?(&1)))
         end) do
      []
    else
      blocked = external_entries(data)

      entries =
        Map.new(Enum.filter(functions, fn {id, _} -> MapSet.member?(blocked, id) end), fn {id, f} ->
          {id, List.duplicate(:unknown, f.arity)}
        end)

      sites = MapSet.new(targets, &{&1.func_id, &1.idx})

      case solve(functions, entries, %{}, sites, rounds, steps) do
        {:ok, bounds} ->
          for {site, value} <- bounds, Value.finite_chars?(value), do: site

        :unknown ->
          []
      end
    end
  end

  defp functions(data, calls, targets) do
    edges = for site <- calls, elem(site.mfa, 0) == data.module, do: {site.func_id, id(site.mfa)}
    relevant = connected(Enum.map(targets, & &1.func_id), edges, %{})
    indexed = Enum.group_by(calls, & &1.func_id)

    for {:function, name, arity, _, instrs} <- data.functions,
        func = InstrId.func_id(data.module, name, arity),
        Map.has_key?(relevant, func),
        into: %{} do
      cfg = data |> Helpers.cfg(name, arity) |> SecurityValues.proof_cfg(instrs)

      {func,
       %{
         arity: arity,
         instrs: instrs,
         code: List.to_tuple(instrs),
         cfg: cfg,
         calls: Map.new(Map.get(indexed, func, []), &{&1.idx, &1})
       }}
    end
  end

  # Instruction writers identify dynamic values only while the CFG is acyclic.
  # Natural-loop metadata alone does not cover irreducible control flow.
  defp cyclic?(cfg) do
    edges =
      Map.new(cfg.blocks, fn {id, block} ->
        {id, block.succs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}
      end)

    counts = Map.new(edges, fn {id, _} -> {id, 0} end)

    counts =
      Enum.reduce(edges, counts, fn {_, successors}, degrees ->
        Enum.reduce(successors, degrees, &Map.update(&2, &1, 1, fn n -> n + 1 end))
      end)

    ready = for {id, 0} <- counts, do: id
    remove_acyclic(ready, edges, counts, 0) != map_size(edges)
  end

  defp remove_acyclic([], _, _, removed), do: removed

  defp remove_acyclic([id | rest], edges, counts, removed) do
    {ready, counts} =
      Enum.reduce(Map.get(edges, id, []), {rest, counts}, fn next, {ready, counts} ->
        n = Map.fetch!(counts, next) - 1
        {if(n == 0, do: [next | ready], else: ready), Map.put(counts, next, n)}
      end)

    remove_acyclic(ready, edges, counts, removed + 1)
  end

  defp connected([], _, seen), do: seen

  defp connected([f | rest], edges, seen) do
    if Map.has_key?(seen, f) do
      connected(rest, edges, seen)
    else
      neighbours = for {a, b} <- edges, a == f or b == f, do: if(a == f, do: b, else: a)
      connected(rest ++ neighbours, edges, Map.put(seen, f, true))
    end
  end

  defp external_entries(data) do
    exported = Enum.map(data.exports, fn {f, a, _} -> InstrId.func_id(data.module, f, a) end)

    captured =
      for {:function, _, _, _, instrs} <- data.functions,
          {:make_fun3, {m, f, a}, _, _, _, _} <- instrs,
          m == data.module,
          do: InstrId.func_id(m, f, a)

    # Older or unsupported capture encodings cannot establish private callers.
    unknown_capture =
      Enum.any?(data.functions, fn {:function, _, _, _, ins} ->
        Enum.any?(ins, &(is_tuple(&1) and elem(&1, 0) in [:make_fun, :make_fun2]))
      end)

    if unknown_capture do
      MapSet.new(data.functions, fn {:function, f, a, _, _} ->
        InstrId.func_id(data.module, f, a)
      end)
    else
      MapSet.new(exported ++ captured)
    end
  end

  defp id({m, f, a}), do: InstrId.func_id(m, f, a)
  defp solve(_, _, _, _, 0, _), do: :unknown
  defp solve(_, _, _, _, _, steps) when steps <= 0, do: :unknown

  defp solve(functions, entries, returns, sites, rounds, steps) do
    outcome =
      Enum.reduce_while(Enum.sort(functions), {entries, returns, %{}, steps}, fn {func, fun},
                                                                                 {ins, outs,
                                                                                  bounds, left} ->
        case Map.fetch(entries, func) do
          :error ->
            {:cont, {ins, outs, bounds, left}}

          {:ok, args} ->
            case run(fun, func, args, returns, functions, sites, left) do
              :unknown ->
                {:halt, :unknown}

              {:ok, requested, returned, found, remaining} ->
                next_ins =
                  Enum.reduce(requested, ins, fn {callee, values}, acc ->
                    Map.update(acc, callee, values, &join_args(&1, values))
                  end)

                next_out = Map.update(outs, func, returned, &Value.join(&1, returned))
                {:cont, {next_ins, next_out, Map.merge(bounds, found), remaining}}
            end
        end
      end)

    case outcome do
      :unknown ->
        :unknown

      {^entries, ^returns, bounds, _} ->
        {:ok, bounds}

      {next_entries, next_returns, _, remaining} ->
        solve(functions, next_entries, next_returns, sites, rounds - 1, remaining)
    end
  end

  defp join_args(a, b), do: Enum.zip_with(a, b, &Value.join/2)

  defp run(fun, func, args, returns, functions, sites, steps) do
    regs = Map.new(Enum.with_index(args), fn {_, pos} -> {{:x, pos}, {:param, pos}} end)
    env = Map.new(Enum.with_index(args), fn {value, pos} -> {{:param, pos}, value} end)
    entry = %{regs: regs, env: env, alive: true}
    ctx = %{fun: fun, func: func, returns: returns, functions: functions, sites: sites}
    blocks([fun.cfg.entry], %{fun.cfg.entry => entry}, %{}, :bottom, %{}, ctx, steps, %{})
  end

  defp blocks([], _, calls, returned, bounds, _, steps, _),
    do: {:ok, calls, returned, bounds, steps}

  defp blocks(_, _, _, _, _, _, steps, _) when steps <= 0, do: :unknown

  defp blocks([block | rest], incoming, calls, returned, bounds, ctx, steps, visits) do
    count = Map.get(visits, block, 0)
    %{range: {first, last}, succs: succs} = Map.fetch!(ctx.fun.cfg.blocks, block)

    if count >= @max_states do
      :unknown
    else
      {after_state, before_last, calls, bounds, steps} =
        Enum.reduce_while(
          first..last,
          {Map.fetch!(incoming, block), nil, calls, bounds, steps},
          fn at, {st, _, calls, bounds, left} ->
            if st.alive and left > 0 do
              bounds =
                if MapSet.member?(ctx.sites, {ctx.func, at}),
                  do:
                    Map.update(
                      bounds,
                      {ctx.func, at},
                      value(st, {:x, 0}),
                      &Value.join(&1, value(st, {:x, 0}))
                    ),
                  else: bounds

              {out, calls} = transfer(ctx, at, st, calls)
              {:cont, {out, st, calls, bounds, left - 1}}
            else
              {:halt, {st, nil, calls, bounds, left}}
            end
          end
        )

      instr = elem(ctx.fun.code, last)

      returned =
        if after_state.alive and (instr == :return or Instr.tail_call?(instr)),
          do: Value.join(returned, value(after_state, {:x, 0})),
          else: returned

      {incoming, changed} =
        Enum.reduce(succs, {incoming, []}, fn {next, edge}, {ins, changed} ->
          case edge_state(instr, last, edge, before_last, after_state) do
            nil ->
              {ins, changed}

            out ->
              out = prune(out)

              merged =
                if Map.has_key?(ins, next), do: merge(Map.fetch!(ins, next), out, next), else: out

              if Map.get(ins, next) == merged,
                do: {ins, changed},
                else: {Map.put(ins, next, merged), [next | changed]}
          end
        end)

      blocks(
        Enum.uniq(rest ++ Enum.reverse(changed)),
        incoming,
        calls,
        returned,
        bounds,
        ctx,
        steps,
        Map.put(visits, block, count + 1)
      )
    end
  end

  defp transfer(ctx, at, st, calls) do
    instr = elem(ctx.fun.code, at)

    case Map.get(ctx.fun.calls, at) do
      nil ->
        {ordinary(instr, at, st), calls}

      site ->
        args = for pos <- 0..(elem(site.mfa, 2) - 1)//1, do: value(st, {:x, pos})
        callee = id(site.mfa)
        local? = Map.has_key?(ctx.functions, callee)
        calls = if local?, do: Map.update(calls, callee, args, &join_args(&1, args)), else: calls

        result =
          if local?, do: Map.get(ctx.returns, callee, :bottom), else: remote(site.mfa, args)

        out = st |> carry(instr) |> put({:x, 0}, {:made, at, {:x, 0}}, result)
        {%{out | alive: result != :bottom}, calls}
    end
  end

  defp ordinary(instr, at, st) do
    cond do
      not Instr.known?(instr) ->
        %{st | regs: %{}, env: %{}}

      match?({:trim, _, _}, instr) ->
        trim(st, instr)

      true ->
        Enum.reduce(Instr.defs(instr), carry(st, instr), fn reg, out ->
          ref =
            case Instr.copy_source(instr, reg) do
              nil -> made_ref(instr, reg, at, st)
              src -> reference(st, src)
            end

          case ref do
            {:value, domain} -> put(out, reg, {:made, at, reg}, domain)
            identity -> %{out | regs: Map.put(out.regs, reg, identity)}
          end
        end)
    end
  end

  defp carry(st, instr),
    do: %{st | regs: Map.reject(st.regs, fn {reg, _} -> Instr.clobbers?(instr, reg) end)}

  defp put(st, reg, identity, domain),
    do: %{st | regs: Map.put(st.regs, reg, identity), env: Map.put(st.env, identity, domain)}

  defp made_ref({:get_list, src, head, _}, reg, _, st),
    do: {if(Instr.register(head) == reg, do: :head, else: :tail), reference(st, src)}

  defp made_ref({:get_hd, src, _}, _, _, st), do: {:head, reference(st, src)}
  defp made_ref({:get_tl, src, _}, _, _, st), do: {:tail, reference(st, src)}
  defp made_ref({:get_tuple_element, src, n, _}, _, _, st), do: {:field, reference(st, src), n}

  defp made_ref({:put_tuple2, _, {:list, args}}, _, _, st),
    do: {:value, Value.tuple(Enum.map(args, &value(st, &1)))}

  defp made_ref({:put_list, head, tail, _}, _, _, st),
    do: {:value, Value.cons(value(st, head), value(st, tail))}

  defp made_ref({:bif, name, _, args, _}, _, _, st), do: bif(name, args, st)
  defp made_ref({:gc_bif, name, _, _, args, _}, _, _, st), do: bif(name, args, st)
  defp made_ref(_, _, _, _), do: {:value, :unknown}

  defp bif(:hd, [src], st), do: {:head, reference(st, src)}
  defp bif(:tl, [src], st), do: {:tail, reference(st, src)}

  defp bif(:element, [index, src], st) do
    case value(st, index) do
      {:literal, n} when is_integer(n) and n > 0 -> {:field, reference(st, src), n - 1}
      _ -> {:value, :unknown}
    end
  end

  defp bif(_, _, _), do: {:value, :unknown}

  defp remote({:lists, :reverse, 1}, [seq]), do: Value.reverse(seq)
  defp remote({Enum, :reverse, 1}, [seq]), do: Value.reverse(seq)
  defp remote({:erlang, :++, 2}, [a, b]), do: Value.append(a, b)
  defp remote({:lists, :append, 2}, [a, b]), do: Value.append(a, b)
  defp remote(_, _), do: :unknown

  defp trim(st, {:trim, removed, _}) do
    %{
      st
      | regs:
          Map.new(
            for {reg, ref} <- st.regs,
                elem(reg, 0) != :y or elem(reg, 1) >= removed,
                do: {if(elem(reg, 0) == :y, do: {:y, elem(reg, 1) - removed}, else: reg), ref}
          )
    }
  end

  defp reference(_st, operand) when is_integer(operand), do: {:constant, {:literal, operand}}

  defp reference(st, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        Map.get(st.regs, reg, :unknown)

      {kind, literal} when kind in [:atom, :literal, :integer, :float] ->
        {:constant, Value.literal(literal)}

      nil ->
        {:constant, Value.empty()}

      _ ->
        :unknown
    end
  end

  defp value(st, operand), do: domain(st, reference(st, operand))

  defp domain(st, ref) do
    base = Map.get_lazy(st.env, ref, fn -> derived(st, ref) end)

    case Map.fetch(st.env, {:head, ref}) do
      {:ok, head} -> Value.singleton_head(base, head)
      :error -> base
    end
  end

  defp derived(_, {:constant, value}), do: value
  defp derived(st, {:head, parent}), do: Value.head(domain(st, parent))
  defp derived(st, {:tail, parent}), do: Value.tail(domain(st, parent))
  defp derived(st, {:field, parent, n}), do: Value.field(domain(st, parent), n)
  defp derived(_, _), do: :unknown

  defp edge_state(_, _, :exception, nil, _), do: nil

  defp edge_state(_, at, :exception, before, _) do
    regs = Map.reject(before.regs, fn {{kind, _}, _} -> kind == :x end)
    out = %{before | regs: regs, alive: true}
    Enum.reduce(0..2, out, &put(&2, {:x, &1}, {:exception, at, &1}, :unknown))
  end

  defp edge_state(_, _, _, _, %{alive: false}), do: nil

  defp edge_state({:test, op, _, args}, _at, edge, before, after_st)
       when edge in [:branch_pass, :branch_fail],
       do: guard(after_st, op, Enum.map(args, &reference(before, &1)), edge == :branch_pass)

  defp edge_state({:select_tuple_arity, src, _, _}, _at, {:select_arm, size}, before, after_st) do
    case Integer.parse(to_string(size)) do
      {n, ""} -> refine(after_st, reference(before, src), &Value.arity(&1, n))
      _ -> after_st
    end
  end

  defp edge_state(_, _, _, _, after_st), do: after_st

  defp guard(st, :is_nil, [ref], true), do: refine_length(st, ref, 0, 0)
  defp guard(st, :is_nonempty_list, [ref], true), do: refine_length(st, ref, 1, :infinity)
  defp guard(st, :is_list, [ref], true), do: refine_length(st, ref, 0, :infinity)

  defp guard(st, :is_tagged_tuple, [ref, {:constant, {:literal, size}}, _], true),
    do: refine(st, ref, &Value.arity(&1, size))

  defp guard(st, op, [a, b], pass) when op in [:is_ge, :is_lt] do
    relation = if op == :is_ge == pass, do: :ge, else: :lt

    case {domain(st, a), domain(st, b)} do
      {_, {:literal, n}} when is_number(n) -> refine(st, a, &Value.range(&1, relation, n, :right))
      {{:literal, n}, _} when is_number(n) -> refine(st, b, &Value.range(&1, relation, n, :left))
      _ -> st
    end
  end

  defp guard(st, _, _, _), do: st

  defp refine(st, :unknown, _fun), do: st

  defp refine(st, ref, fun) do
    result = fun.(domain(st, ref))
    if result == :bottom, do: nil, else: %{st | env: Map.put(st.env, ref, result)}
  end

  defp refine_length(st, {:tail, parent} = ref, lo, hi) do
    with next when next != nil <- refine(st, ref, &Value.length_between(&1, lo, hi)),
         parent_state when parent_state != nil <-
           refine(next, parent, &Value.length_between(&1, lo + 1, increment(hi))) do
      parent_state
    end
  end

  defp refine_length(st, ref, lo, hi), do: refine(st, ref, &Value.length_between(&1, lo, hi))
  defp increment(:infinity), do: :infinity
  defp increment(n), do: n + 1

  defp merge(a, b, block) do
    regs =
      for reg <- Enum.uniq(Map.keys(a.regs) ++ Map.keys(b.regs)), into: %{} do
        ra = Map.get(a.regs, reg, :unknown)
        rb = Map.get(b.regs, reg, :unknown)
        {reg, if(ra == rb, do: ra, else: {:phi, block, reg})}
      end

    env =
      for ref <- Enum.uniq(Map.keys(a.env) ++ Map.keys(b.env)),
          into: %{},
          do: {ref, Value.join(domain(a, ref), domain(b, ref))}

    env =
      Enum.reduce(regs, env, fn {reg, ref}, acc ->
        Map.put(acc, ref, Value.join(value(a, reg), value(b, reg)))
      end)

    prune(%{regs: regs, env: env, alive: true})
  end

  defp prune(st) do
    keep = Enum.reduce(Map.values(st.regs), MapSet.new(), &parents/2)
    %{st | env: Map.take(st.env, MapSet.to_list(keep))}
  end

  defp parents({kind, parent} = ref, seen) when kind in [:head, :tail],
    do: parents(parent, MapSet.put(seen, ref))

  defp parents({:field, parent, _} = ref, seen), do: parents(parent, MapSet.put(seen, ref))
  defp parents(ref, seen), do: MapSet.put(seen, ref)
end

defmodule Argus.Extractors.ParamFlow.SequenceBounds.Value do
  @moduledoc false
  @depth 16
  @nodes 4096
  @limit 1024
  @unicode_max 0x10FFFF

  @type alphabet ::
          :any
          | :none
          | {integer() | :negative_infinity, integer() | :positive_infinity}
  @type length_bound :: non_neg_integer() | :infinity
  @type t ::
          :unknown
          | :bottom
          | {:literal, atom() | number()}
          | {:chars, alphabet()}
          | {:list, alphabet(), non_neg_integer(), length_bound()}
          | {:cons, t(), t()}
          | {:tuples, %{non_neg_integer() => %{non_neg_integer() => t()}}}

  @spec empty() :: t()
  def empty, do: {:list, :none, 0, 0}
  @spec literal(term()) :: t()
  def literal(v), do: finish(literal(v, @depth, @nodes))
  defp literal(_, _, 0), do: :overflow
  defp literal(_, 0, left), do: {:ok, :unknown, left - 1}
  defp literal([], _, left), do: {:ok, empty(), left - 1}

  defp literal([h | t], depth, left) do
    with {:ok, head, left} <- literal(h, depth - 1, left - 1),
         {:ok, tail, left} <- literal(t, depth - 1, left) do
      {:ok, {:cons, head, tail}, left}
    end
  end

  defp literal(v, depth, left) when is_tuple(v) and tuple_size(v) <= 32 do
    fields = Map.new(Enum.with_index(Tuple.to_list(v)), fn {value, i} -> {i, value} end)

    with {:ok, fields, left} <- walk_fields(fields, depth - 1, left - 1, &literal/3) do
      {:ok, {:tuples, %{tuple_size(v) => fields}}, left}
    end
  end

  defp literal(v, _, left) when is_atom(v) or is_number(v),
    do: {:ok, {:literal, v}, left - 1}

  defp literal(_, _, left), do: {:ok, :unknown, left - 1}

  @spec tuple([t()]) :: t()
  def tuple(fields) when length(fields) <= 32,
    do:
      cap(
        {:tuples, %{length(fields) => Map.new(Enum.with_index(fields), fn {v, i} -> {i, v} end)}}
      )

  def tuple(_), do: :unknown
  @spec cons(t(), t()) :: t()
  def cons(head, tail), do: cap({:cons, head, tail})

  # Depth alone cannot bound duplicated tuple fields: a small BEAM may build a
  # shared DAG whose expanded abstract tree has exponentially many nodes.
  defp cap(value), do: finish(walk(value, @depth, @nodes))
  defp finish({:ok, value, _}), do: value
  defp finish(:overflow), do: :unknown

  defp walk(_, _, 0), do: :overflow
  defp walk(_, 0, left), do: {:ok, :unknown, left - 1}

  defp walk({:cons, h, t}, depth, left) do
    with {:ok, head, left} <- walk(h, depth - 1, left - 1),
         {:ok, tail, left} <- walk(t, depth - 1, left) do
      {:ok, {:cons, head, tail}, left}
    end
  end

  defp walk({:tuples, shapes}, depth, left) do
    Enum.reduce_while(shapes, {:ok, %{}, left - 1}, fn {size, fields}, {:ok, out, left} ->
      case walk_fields(fields, depth - 1, left, &walk/3) do
        {:ok, next, left} -> {:cont, {:ok, Map.put(out, size, next), left}}
        :overflow -> {:halt, :overflow}
      end
    end)
    |> case do
      {:ok, shapes, left} -> {:ok, {:tuples, shapes}, left}
      :overflow -> :overflow
    end
  end

  defp walk(other, _, left), do: {:ok, other, left - 1}

  defp walk_fields(fields, depth, left, visitor) do
    Enum.reduce_while(fields, {:ok, %{}, left}, fn {i, value}, {:ok, out, left} ->
      case visitor.(value, depth, left) do
        {:ok, next, left} -> {:cont, {:ok, Map.put(out, i, next), left}}
        :overflow -> {:halt, :overflow}
      end
    end)
  end

  @spec join(t(), t()) :: t()
  def join(a, b), do: cap(join_values(a, b))

  defp join_values(:bottom, b), do: b
  defp join_values(a, :bottom), do: a
  defp join_values(a, a), do: a
  defp join_values({:chars, a}, {:chars, b}), do: {:chars, alphabet_join(a, b)}
  defp join_values({:chars, a}, {:literal, _} = b), do: {:chars, alphabet_join(a, alphabet(b))}
  defp join_values({:literal, _} = a, {:chars, b}), do: {:chars, alphabet_join(alphabet(a), b)}

  defp join_values({:literal, a}, {:literal, b}) when is_number(a) and is_number(b),
    do: {:chars, alphabet_join(alphabet({:literal, a}), alphabet({:literal, b}))}

  defp join_values(:unknown, _), do: :unknown
  defp join_values(_, :unknown), do: :unknown

  defp join_values({:tuples, a}, {:tuples, b}) when map_size(a) + map_size(b) <= 16,
    do:
      {:tuples,
       Map.merge(a, b, fn size, fa, fb ->
         Map.new(0..(size - 1)//1, fn i ->
           {i, join_values(Map.get(fa, i, :unknown), Map.get(fb, i, :unknown))}
         end)
       end)}

  defp join_values(a, b) do
    case {sequence(a), sequence(b)} do
      {{aa, al, ah}, {ba, bl, bh}} ->
        {:list, alphabet_join(aa, ba), min(al, bl), if(ah == bh, do: ah, else: :infinity)}

      _ ->
        :unknown
    end
  end

  @spec field(t(), non_neg_integer()) :: t()
  def field({:tuples, sizes}, n),
    do:
      Enum.reduce(sizes, :bottom, fn {size, fields}, out ->
        if n < size, do: join(out, Map.get(fields, n, :unknown)), else: out
      end)

  def field(_, _), do: :unknown

  @spec arity(t(), term()) :: t()
  def arity({:tuples, sizes}, n),
    do: if(Map.has_key?(sizes, n), do: {:tuples, Map.take(sizes, [n])}, else: :bottom)

  def arity(:bottom, _), do: :bottom
  def arity(_, n) when is_integer(n) and n >= 0 and n <= 32, do: {:tuples, %{n => %{}}}
  def arity(_, _), do: :unknown

  @spec singleton_head(t(), t()) :: t()
  def singleton_head({:list, alpha, 1, 1}, head),
    do: {:list, intersect(alpha, alphabet(head)), 1, 1}

  def singleton_head(value, _), do: value

  @spec head(t()) :: t()
  def head({:cons, h, _}), do: h
  def head({:list, alpha, _, _}), do: {:chars, alpha}
  def head(_), do: :unknown
  @spec tail(t()) :: t()
  def tail({:cons, _, t}), do: t
  def tail({:list, alpha, lo, hi}), do: {:list, alpha, max(lo - 1, 0), decrement(hi)}
  def tail(_), do: :unknown
  defp decrement(:infinity), do: :infinity
  defp decrement(n), do: max(n - 1, 0)

  @spec reverse(t()) :: t()
  def reverse(value) do
    case sequence(value) do
      {a, lo, hi} -> {:list, a, lo, hi}
      _ -> :unknown
    end
  end

  @spec append(t(), t()) :: t()
  def append({:cons, h, t}, b), do: cons(h, append(t, b))
  def append({:list, _, 0, 0}, b), do: b
  def append(_, _), do: :unknown

  @spec length_between(t(), non_neg_integer(), length_bound()) :: t()
  def length_between(value, lo, hi) do
    case sequence(value) do
      {alpha, old_lo, old_hi} ->
        lower = max(lo, old_lo)
        upper = minimum(hi, old_hi)
        if upper != :infinity and lower > upper, do: :bottom, else: {:list, alpha, lower, upper}

      _ ->
        {:list, :any, lo, hi}
    end
  end

  defp minimum(:infinity, b), do: b
  defp minimum(a, :infinity), do: a
  defp minimum(a, b), do: min(a, b)

  @spec range(t(), :ge | :lt, number(), :left | :right) :: t()
  def range({:literal, _} = value, _, _, _), do: value

  def range(value, comparison, bound, side) do
    restriction =
      case {comparison, side} do
        {:ge, :right} -> {ceil(bound), :positive_infinity}
        {:lt, :right} -> {:negative_infinity, ceil(bound) - 1}
        {:ge, :left} -> {:negative_infinity, floor(bound)}
        {:lt, :left} -> {floor(bound) + 1, :positive_infinity}
      end

    {:chars, intersect(alphabet(value), restriction)}
  end

  @spec finite_chars?(t()) :: boolean()
  def finite_chars?(value) do
    case names(value, @limit) do
      n when is_integer(n) -> n > 0 and n <= @limit
      _ -> false
    end
  end

  defp names({:cons, h, t}, limit) do
    a = letters(alphabet(h))
    b = names(t, limit)
    if is_integer(a) and is_integer(b) and a * b <= limit, do: a * b, else: :unknown
  end

  defp names({:list, _, 0, 0}, _), do: 1

  defp names({:list, alpha, lo, hi}, limit) when is_integer(hi) and hi <= 16 do
    case letters(alpha) do
      n when is_integer(n) ->
        Enum.reduce_while(lo..hi, 0, fn size, total ->
          count = Integer.pow(n, size)
          if total + count <= limit, do: {:cont, total + count}, else: {:halt, :unknown}
        end)

      _ ->
        :unknown
    end
  end

  defp names(_, _), do: :unknown

  defp letters(:none), do: 0

  defp letters({lo, hi}) when is_integer(lo) and is_integer(hi),
    do: max(min(hi, @unicode_max) - max(lo, 0) + 1, 0)

  defp letters(_), do: :unknown
  defp alphabet({:chars, range}), do: range
  defp alphabet({:literal, n}) when is_integer(n), do: {n, n}
  defp alphabet({:literal, _}), do: :none
  defp alphabet(_), do: :any

  defp sequence({:list, a, lo, hi}), do: {a, lo, hi}

  defp sequence({:cons, h, t}) do
    case sequence(t) do
      {a, lo, hi} ->
        {alphabet_join(alphabet(h), a), lo + 1, if(hi == :infinity, do: :infinity, else: hi + 1)}

      _ ->
        nil
    end
  end

  defp sequence(_), do: nil

  defp alphabet_join(:none, b), do: b
  defp alphabet_join(a, :none), do: a
  defp alphabet_join(:any, _), do: :any
  defp alphabet_join(_, :any), do: :any
  defp alphabet_join({al, ah}, {bl, bh}), do: {low_min(al, bl), high_max(ah, bh)}
  defp low_min(:negative_infinity, _), do: :negative_infinity
  defp low_min(_, :negative_infinity), do: :negative_infinity
  defp low_min(a, b), do: min(a, b)
  defp high_max(:positive_infinity, _), do: :positive_infinity
  defp high_max(_, :positive_infinity), do: :positive_infinity
  defp high_max(a, b), do: max(a, b)

  defp intersect(_, :none), do: :none
  defp intersect(a, :any), do: a
  defp intersect(:none, _), do: :none
  defp intersect(:any, b), do: b

  defp intersect({al, ah}, {bl, bh}) do
    lo =
      if al == :negative_infinity,
        do: bl,
        else: if(bl == :negative_infinity, do: al, else: max(al, bl))

    hi =
      if ah == :positive_infinity,
        do: bh,
        else: if(bh == :positive_infinity, do: ah, else: min(ah, bh))

    if is_integer(lo) and is_integer(hi) and lo > hi, do: :none, else: {lo, hi}
  end
end
