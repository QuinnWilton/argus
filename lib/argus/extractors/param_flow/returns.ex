defmodule Argus.Extractors.ParamFlow.Returns do
  @moduledoc false

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  @type origin :: non_neg_integer() | :chosen | {:runtime, String.t(), String.t()}
  @type summary :: MapSet.t(origin())
  @type summaries :: %{String.t() => summary()}
  @type inputs :: %{String.t() => summary()}
  @type closure :: %{
          target: String.t(),
          at: non_neg_integer(),
          first: arity(),
          env: [term()],
          fallback: summary()
        }
  @type callback :: %{
          closure: closure() | nil,
          args: [non_neg_integer()],
          base: [non_neg_integer()]
        }
  @type callbacks :: %{InstrId.t() => callback()}
  @type targets :: %{InstrId.t() => String.t()}

  # {fun position, callback arguments' source positions, result's other
  # source positions}. Predicate callbacks do not contribute their return
  # data to filter/find/sort_by, and are deliberately absent here.
  @callbacks %{
    {Enum, :map, 2} => {1, [0], []},
    {Enum, :flat_map, 2} => {1, [0], []},
    {Enum, :map_join, 2} => {1, [0], []},
    {Enum, :map_join, 3} => {2, [0], [1]},
    {Enum, :into, 3} => {2, [0], [1]},
    {Enum, :group_by, 2} => {1, [0], [0]},
    {Enum, :reduce, 2} => {1, [0, 0], [0]},
    {Enum, :reduce, 3} => {2, [0, 1], [1]},
    {Map, :new, 2} => {1, [0], []},
    {:lists, :map, 2} => {0, [1], []},
    {:lists, :flatmap, 2} => {0, [1], []},
    {:lists, :foldl, 3} => {0, [2, 1], [1]},
    {:lists, :foldr, 3} => {0, [2, 1], [1]}
  }

  # Calls to a function defined in this module use its actual summary,
  # including remote self-calls. Nothing depends on which other modules
  # or extractors happen to run alongside this producer.
  @spec index(Argus.Extractor.module_data()) :: {targets(), callbacks()}
  def index(module_data) do
    targets =
      Map.new(CallSites.for_module(module_data), fn site ->
        {mod, fun, arity} = site.mfa
        {id(site.func_id, site.idx), Normalize.func_id(mod, fun, arity)}
      end)

    callbacks =
      for site <- CallSites.for_module(module_data),
          {:ok, {fun_pos, args, base}} <- [Map.fetch(@callbacks, site.mfa)],
          into: %{} do
        {id(site.func_id, site.idx),
         %{closure: closure(site.instrs, site.idx, {:x, fun_pos}), args: args, base: base}}
      end

    direct =
      for {:function, name, arity, _entry, instrs} <- module_data.functions,
          func = Normalize.func_id(module_data.module, name, arity),
          {instr, idx} <- Enum.with_index(instrs),
          {n, reg} <- direct_fun(instr),
          into: %{} do
        {id(func, idx),
         %{closure: closure(instrs, idx, reg), args: Enum.to_list(0..(n - 1)//1), base: []}}
      end

    {targets, Map.merge(callbacks, direct)}
  end

  defp direct_fun({:call_fun, arity}), do: [{arity, {:x, arity}}]
  defp direct_fun({:call_fun2, _tag, arity, fun}), do: [{arity, fun}]
  defp direct_fun(_instr), do: []

  defp closure(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, nil, fn
      {at, {:make_fun3, {mod, fun, arity}, _index, _uniq, _dst, {:list, env}}}, _follow ->
        %{
          target: Normalize.func_id(mod, fun, arity),
          at: at,
          first: arity - length(env),
          env: env,
          fallback: MapSet.new()
        }

      _writer, _follow ->
        nil
    end) || external_fun(instrs, idx, reg)
  end

  defp external_fun(instrs, idx, reg) do
    case Resolve.fun_origin(instrs, idx, reg) do
      {:external, {mod, fun, arity}} ->
        %{
          target: Normalize.func_id(mod, fun, arity),
          at: idx,
          first: arity,
          env: [],
          fallback:
            MapSet.new(Propagators.positions(inspect(mod), Atom.to_string(fun), arity) || [])
        }

      _ ->
        nil
    end
  end

  # Capture reads occur at make_fun, not when the callback runs. A changed
  # write feeding a capture must revisit that callback even though fun
  # construction does not copy its captured data into the fun value.
  @spec capture_users(callbacks(), Argus.Extractor.ValueFlow.reads()) ::
          %{non_neg_integer() => [non_neg_integer()]}
  def capture_users(callbacks, reads) do
    for {id, %{closure: %{at: at, env: env}}} <- callbacks,
        operand <- env,
        reg = Instr.spell_slot(operand),
        {:def, source} <- Map.get(Map.get(reads, at, %{}), reg, []),
        reduce: %{} do
      acc -> Map.update(acc, source, [id.idx], &[id.idx | &1])
    end
  end

  @spec callback_result(callback(), inputs(), summaries(), (non_neg_integer() -> inputs())) ::
          summary()
  def callback_result(%{closure: closure, args: args, base: base}, inputs, summaries, at) do
    base = union(inputs, Enum.map(base, &"x#{&1}"))

    case closure do
      %{target: target, at: creation, first: first, env: env, fallback: fallback} ->
        captures = at.(creation)

        summaries
        |> Map.get(target, fallback)
        |> Enum.reduce(base, fn
          :chosen, acc ->
            MapSet.put(acc, :chosen)

          {:runtime, _, _} = source, acc ->
            MapSet.put(acc, source)

          param, acc when param < first ->
            MapSet.union(acc, Map.get(inputs, "x#{Enum.at(args, param)}", MapSet.new()))

          param, acc ->
            reg = env |> Enum.at(param - first) |> Instr.spell_slot()
            MapSet.union(acc, Map.get(captures, reg, MapSet.new()))
        end)

      nil ->
        base
    end
  end

  @spec substitute(summary(), inputs()) :: summary()
  def substitute(summary, inputs) do
    Enum.reduce(summary, MapSet.new(), fn
      :chosen, acc -> MapSet.put(acc, :chosen)
      {:runtime, _, _} = source, acc -> MapSet.put(acc, source)
      param, acc -> MapSet.union(acc, Map.get(inputs, "x#{param}", MapSet.new()))
    end)
  end

  defp union(inputs, regs) do
    Enum.reduce(regs, MapSet.new(), &MapSet.union(&2, Map.get(inputs, &1, MapSet.new())))
  end

  # The finite summaries contain parameter positions, callback origins and the
  # existing-atom marker. Starting empty and revisiting callers gives a least fixpoint,
  # including mutually recursive helpers, without tainting unknown calls.
  @spec solve(
          %{String.t() => input},
          targets(),
          callbacks(),
          (input, summaries() -> {result, summary()})
        ) :: %{String.t() => result}
        when input: term(), result: term()
  def solve(functions, targets, callbacks, evaluate) do
    users =
      Enum.reduce(targets, %{}, fn {id, target}, acc ->
        Map.update(acc, target, [function_of(id)], &[function_of(id) | &1])
      end)

    users =
      Enum.reduce(callbacks, users, fn
        {id, %{closure: %{target: target}}}, acc ->
          Map.update(acc, target, [function_of(id)], &[function_of(id) | &1])

        _, acc ->
          acc
      end)

    funcs = functions |> Map.keys() |> Enum.sort()
    summaries = Map.new(funcs, &{&1, MapSet.new()})
    run(:queue.from_list(funcs), MapSet.new(funcs), functions, users, summaries, %{}, evaluate)
  end

  defp run(queue, pending, functions, users, summaries, solved, evaluate) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        solved

      {{:value, func}, queue} ->
        pending = MapSet.delete(pending, func)
        {result, summary} = evaluate.(Map.fetch!(functions, func), summaries)
        solved = Map.put(solved, func, result)

        {queue, pending} =
          if Map.get(summaries, func, MapSet.new()) == summary do
            {queue, pending}
          else
            users
            |> Map.get(func, [])
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.reduce({queue, pending}, fn caller, {queue, pending} ->
              if MapSet.member?(pending, caller),
                do: {queue, pending},
                else: {:queue.in(caller, queue), MapSet.put(pending, caller)}
            end)
          end

        run(queue, pending, functions, users, Map.put(summaries, func, summary), solved, evaluate)
    end
  end

  defp id(func, idx) do
    {:ok, id} = InstrId.parse(InstrId.mint(func, idx))
    id
  end

  defp function_of(id), do: InstrId.func_id(id.module, id.func, id.arity)
end
