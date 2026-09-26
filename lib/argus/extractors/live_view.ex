defmodule Argus.Extractors.LiveView do
  @moduledoc """
  Where a LiveView's code asks whether it is connected.

  A LiveView's `mount/3` (and `handle_params/3`, and a LiveComponent's
  `mount/1` and `update/2`) runs twice: once for the static render, in
  the HTTP connection's process, and again in the LiveView's own
  process once the socket connects. `Phoenix.LiveView.connected?/1` —
  or `get_connect_params/1`, which is nil on the static render — tells
  the two apart, and what registers the process for later messages (a
  PubSub subscription, a timer, a monitor) belongs behind it: on the
  static render it registers the HTTP connection's process, which lives
  on for a keep-alive client and takes every message meant for the
  LiveView.

  ## Emitted facts

  - `pubsub_call(id, func, op, via)` — the call at `id` subscribes the
    process to a topic or a group (`op` `subscribe`), or undoes one
    (`unsubscribe`): through Phoenix.PubSub or `:pg` (`via` `pubsub`),
    a module's own `subscribe/1,2` or `unsubscribe/1` (`via` the module,
    an endpoint when it is one), or an apply of either name to a module
    held in a value (`apply`: `socket.endpoint.subscribe(topic)`).
  - `param_decided(id, func, pos)` — the call at `id` (into the program,
    or a subscription) runs only on some arms of a test of what `func`'s
    parameter `pos` holds: the parameter, a field of it, a call's answer
    on it. A test whose other arms only raise decides nothing.
  - `connected_guarded(id, func)` — the call at `id` runs only on the
    arm where a `connected?/1` call answered true (a
    `get_connect_params/1` call, not nil): the block that arm's edge alone
    enters dominates the call's. A call on the other arm runs on the
    static render, and one after the arms join on both.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Block
  alias Argus.Cfg.Function, as: Graph
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Runtime
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @asks [
    {Phoenix.LiveView, :connected?, 1},
    {Phoenix.LiveView, :get_connect_params, 1}
  ]

  @decides [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]

  # Subscriptions and their undoing, by the call's spelling: through
  # Phoenix.PubSub, or through an endpoint's own subscribe/1,2 and
  # unsubscribe/1 (the endpoint a module names, or the one a socket
  # holds, `socket.endpoint.subscribe(topic)`, an apply).
  @pubsub %{
    {Phoenix.PubSub, :subscribe, 2} => "subscribe",
    {Phoenix.PubSub, :subscribe, 3} => "subscribe",
    {Phoenix.PubSub, :unsubscribe, 2} => "unsubscribe",
    {:pg, :join, 2} => "subscribe",
    {:pg, :join, 3} => "subscribe",
    {:pg, :leave, 2} => "unsubscribe",
    {:pg, :leave, 3} => "unsubscribe"
  }

  @endpoint_ops %{
    {:subscribe, 1} => "subscribe",
    {:subscribe, 2} => "subscribe",
    {:unsubscribe, 1} => "unsubscribe"
  }

  # How far back through the writes a test's operand is followed to a
  # parameter: a field of a field, a helper's answer on it.
  @state_depth 8

  @impl true
  def relations, do: [:connected_guarded, :pubsub_call, :param_decided]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    sites = CallSites.for_module(module_data)

    module_data
    |> connected(sites)
    |> pubsub_calls(module_data, sites)
    |> param_decided(module_data, sites)
  end

  # ── Decided by a parameter ──────────────────────────────────────────
  #
  # A call that runs only on some arms of a test of what a function was
  # handed: a parameter, a field of it, a call's answer on it
  # (`MapSet.member?(state.subscribed, id)`, `socket.assigns[:scope_pid]`
  # compared with the current scope's pid). A test whose other arms only
  # raise (a match that fails with a badmatch, a clause head that fails
  # with a function_clause) decides nothing. Recorded for the calls into
  # the program and the subscriptions: what a rule asks of a process's
  # state, when the callback hands the state down.

  defp param_decided(facts, module_data, sites) do
    sites
    |> Enum.filter(&decidable?/1)
    |> Enum.group_by(& &1.func_id)
    |> Enum.reduce(facts, fn {func_id, own}, acc ->
      {name, arity} = Normalize.func_id_name_arity(func_id)

      with true <- arity > 0,
           %Graph{} = graph <- Helpers.cfg(module_data, name, arity) do
        code = own |> hd() |> Map.fetch!(:instrs) |> List.to_tuple()
        tests = param_tests(graph, code, arity)

        for %{idx: idx} <- own,
            pos <- deciding_params(graph, tests, idx),
            reduce: acc do
          inner ->
            add_fact(inner, :param_decided, [
              InstrId.mint(func_id, idx),
              func_id,
              Integer.to_string(pos)
            ])
        end
      else
        _ -> acc
      end
    end)
  end

  # A call into the program, or a subscription.
  defp decidable?(%{remote?: false}), do: true

  defp decidable?(%{mfa: {m, f, a} = mfa}),
    do:
      Map.has_key?(@pubsub, mfa) or Map.has_key?(@endpoint_ops, {f, a}) or not Runtime.module?(m)

  # The blocks ending in a test that decides something (two of its
  # successors can go on to return), each with the parameters its
  # operands are made of.
  defp param_tests(graph, code, arity) do
    completing = completing(graph)
    instrs = Tuple.to_list(code)

    for %Block{id: id, range: {_, last}, succs: succs} <- Map.values(graph.blocks),
        succs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.count(&(&1 in completing)) >= 2,
        params =
          elem(code, last)
          |> tested()
          |> Enum.flat_map(&made_of(instrs, last, Instr.register(&1), arity))
          |> Enum.uniq(),
        params != [],
        do: {id, params}
  end

  defp tested({:test, _op, _fail, operands}) when is_list(operands), do: operands
  defp tested({:test, _op, _fail, _live, operands, _dst}) when is_list(operands), do: operands
  defp tested({:select_val, operand, _fail, _cases}), do: [operand]
  defp tested({:select_tuple_arity, operand, _fail, _cases}), do: [operand]
  defp tested(_instr), do: []

  # The blocks from which some path returns or tail-calls.
  defp completing(graph) do
    ends =
      for %Block{id: id, terminator: t} <- Map.values(graph.blocks),
          t in [:return, :tail_call],
          do: id

    grow(graph, ends, MapSet.new(ends))
  end

  defp grow(_graph, [], seen), do: seen

  defp grow(graph, [id | rest], seen) do
    preds =
      for {from, _kind} <- Map.fetch!(graph.blocks, id).preds,
          not MapSet.member?(seen, from),
          uniq: true,
          do: from

    grow(graph, preds ++ rest, Enum.reduce(preds, seen, &MapSet.put(&2, &1)))
  end

  # The parameters the value in `reg` at `idx` is made of: a parameter
  # itself, or what an instruction or a call made of one.
  defp made_of(instrs, idx, reg, arity) do
    instrs
    |> params_of(idx, reg, @state_depth, %{})
    |> elem(0)
    |> Enum.filter(&(&1 < arity))
  end

  defp params_of(_instrs, _idx, _reg, 0, seen), do: {[], seen}

  defp params_of(instrs, idx, {kind, _} = reg, depth, seen) when kind in [:x, :y] do
    if Map.has_key?(seen, {idx, reg}) do
      {[], seen}
    else
      seen = Map.put(seen, {idx, reg}, true)

      instrs
      |> Resolve.writers(idx, reg)
      |> Enum.reduce({[], seen}, fn
        {:param, k}, {found, seen} ->
          {[k | found], seen}

        at, {found, seen} ->
          instrs
          |> Reaching.at(at)
          |> Instr.uses()
          |> Enum.reduce({found, seen}, fn used, {inner, seen} ->
            {more, seen} = params_of(instrs, at, used, depth - 1, seen)
            {more ++ inner, seen}
          end)
      end)
    end
  end

  defp params_of(_instrs, _idx, _operand, _depth, seen), do: {[], seen}

  # The parameters of the tests that decide whether `idx` runs.
  defp deciding_params(graph, tests, idx) do
    case Graph.block_at(graph, idx) do
      nil ->
        []

      %{id: call} ->
        tests
        |> Enum.filter(fn {test, _params} -> controls?(graph, test, call) end)
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  # `test` decides whether `block` runs: some successor of it dominates
  # `block`, and `block` is not reached whichever way the test goes (it
  # does not post-dominate the test).
  defp controls?(graph, test, block) do
    test != block and not Graph.postdominates?(graph, block, test) and
      Enum.any?(Map.fetch!(graph.blocks, test).succs, fn {succ, _kind} ->
        Graph.dominates?(graph, succ, block)
      end)
  end

  # ── Subscriptions ───────────────────────────────────────────────────

  defp pubsub_calls(facts, %{functions: functions, module: mod}, sites) do
    facts =
      Enum.reduce(sites, facts, fn %{func_id: func_id, idx: idx, mfa: {m, f, a} = mfa}, acc ->
        cond do
          Map.has_key?(@pubsub, mfa) ->
            pubsub_row(acc, func_id, idx, Map.fetch!(@pubsub, mfa), "pubsub")

          Map.has_key?(@endpoint_ops, {f, a}) and not Runtime.module?(m) ->
            pubsub_row(acc, func_id, idx, Map.fetch!(@endpoint_ops, {f, a}), inspect(m))

          true ->
            acc
        end
      end)

    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = InstrId.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {instr, idx}, inner ->
        case applied(instr) do
          nil ->
            inner

          n ->
            with {:ok, fun} when is_atom(fun) <-
                   Resolve.resolve_register(instrs, idx, {:x, n + 1}),
                 {:ok, op} <- Map.fetch(@endpoint_ops, {fun, n}) do
              pubsub_row(inner, func_id, idx, op, "apply")
            else
              _ -> inner
            end
        end
      end)
    end)
  end

  # An apply of a function named in a register to `n` arguments, its
  # module in x(n) and its name in x(n + 1).
  defp applied({:apply, n}), do: n
  defp applied({:apply_last, n, _deallocate}), do: n
  defp applied(_instr), do: nil

  defp pubsub_row(facts, func_id, idx, op, via),
    do: add_fact(facts, :pubsub_call, [InstrId.mint(func_id, idx), func_id, op, via])

  # ── connected? ──────────────────────────────────────────────────────

  defp connected(module_data, sites) do
    sites
    |> Enum.filter(&(&1.mfa in @asks))
    |> Enum.map(& &1.func_id)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn func_id, facts ->
      {name, arity} = Normalize.func_id_name_arity(func_id)

      case Helpers.cfg(module_data, name, arity) do
        nil ->
          facts

        graph ->
          own = Enum.filter(sites, &(&1.func_id == func_id))
          code = own |> hd() |> Map.fetch!(:instrs) |> List.to_tuple()
          asks = for %{mfa: mfa, idx: idx} <- own, mfa in @asks, into: MapSet.new(), do: idx
          arms = connected_arms(graph, code, asks)

          own
          |> Enum.filter(&guarded?(graph, arms, &1.idx))
          |> Enum.reduce(facts, fn %{idx: idx}, acc ->
            add_fact(acc, :connected_guarded, [InstrId.mint(func_id, idx), func_id])
          end)
      end
    end)
  end

  # The blocks that run only when a `connected?` call answered true (a
  # `get_connect_params` call, not nil): for each test of such an answer,
  # the arm its truthy edge leads to, when that edge alone enters it.
  defp connected_arms(graph, code, asks) do
    instrs = Tuple.to_list(code)

    for t <- 0..(tuple_size(code) - 1)//1,
        instr = elem(code, t),
        operand <- decided(instr),
        reg = Instr.register(operand),
        match?({kind, _} when kind in [:x, :y], reg),
        instrs |> Resolve.writers(t, reg) |> Enum.any?(&(&1 in asks)),
        %{id: test, range: {_, ^t}} <- [Graph.block_at(graph, t)],
        arm <- truthy_arms(graph, instr, t),
        %{preds: [{^test, _kind}]} <- [Map.get(graph.blocks, arm)],
        uniq: true,
        do: arm
  end

  defp decided({:test, op, _fail, [a, b]}) when op in @decides, do: [a, b]
  defp decided({:select_val, operand, _fail, _cases}), do: [operand]
  defp decided(_instr), do: []

  # The blocks a test's edges lead to on a truthy answer: an equality
  # with true passes, one with false or nil fails, and the other way
  # round for an inequality; a select's true arm, and its default when
  # the arms take false or nil and not true.
  defp truthy_arms(graph, {:test, op, {:f, fail}, [a, b]}, t) do
    literal = if match?({:atom, _}, b), do: b, else: a
    equal? = op in [:is_eq_exact, :is_eq]

    case {literal, equal?} do
      {{:atom, true}, true} -> [block_at_index(graph, t + 1)]
      {{:atom, true}, false} -> [block_at_label(graph, fail)]
      {{:atom, falsy}, true} when falsy in [false, nil] -> [block_at_label(graph, fail)]
      {{:atom, falsy}, false} when falsy in [false, nil] -> [block_at_index(graph, t + 1)]
      _ -> []
    end
    |> Enum.reject(&is_nil/1)
  end

  defp truthy_arms(graph, {:select_val, _operand, {:f, default}, {:list, pairs}}, _t) do
    values = pairs |> Enum.chunk_every(2) |> Enum.map(&hd/1)

    trues = for [{:atom, true}, {:f, label}] <- Enum.chunk_every(pairs, 2), do: label

    defaults =
      if {:atom, true} not in values and
           Enum.any?(values, &(&1 in [{:atom, false}, {:atom, nil}])),
         do: [default],
         else: []

    (trues ++ defaults)
    |> Enum.map(&block_at_label(graph, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp truthy_arms(_graph, _instr, _t), do: []

  defp block_at_index(graph, idx) do
    case Graph.block_at(graph, idx) do
      %{id: id, range: {^idx, _}} -> id
      _ -> nil
    end
  end

  defp block_at_label(graph, label), do: Map.get(graph.labels, label)

  # A call on such an arm: the arm's block dominates it.
  defp guarded?(graph, arms, idx) do
    case Graph.block_at(graph, idx) do
      nil -> false
      %{id: call} -> Enum.any?(arms, &Graph.dominates?(graph, &1, call))
    end
  end
end
