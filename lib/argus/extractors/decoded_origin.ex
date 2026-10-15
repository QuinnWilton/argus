defmodule Argus.Extractors.DecodedOrigin do
  @moduledoc """
  Where the bytes a deserialization decodes come from, where every way to
  it agrees.

  `binary_to_term` without `:safe` interns any atom its bytes name and
  builds any fun, which is what it is for when the bytes are a BEAM
  file's own terms: a module's literal table, its attributes, its debug
  info and its docs legitimately hold atoms this node has not made and
  funs of modules it has not loaded. The question for those bytes is not
  whether an outsider wrote them but whether the analyzed code is
  trusted, and the answer is a short-lived VM, not `:safe`.

  ## Emitted facts

  - `decoded_origin(id, func, origin)` — the bytes `binary_to_term/1,2`
    decodes at `id` come, on every path, from
    - `artifact`: a BEAM file's chunks or object code
      (`:beam_lib.chunks/2,3`, `:beam_lib.all_chunks/1`,
      `:code.get_object_code/1`), whichever beam the program reads; or
    - `build`: a file whose path is made of the project's own build
      directories (`Mix.Project.manifest_path/0,1`, `build_path/0,1`,
      `app_path/0,1`, `compile_path/0,1`) and literals alone, read
      whole (`File.read/1`, `File.read!/1`, `:file.read_file/1`):
      whoever writes there already runs code through the build.

    A decode some of whose bytes may come from anywhere else has no row.

  ## The walk

  Each function is solved on `Argus.Extractor.ValueFlow` over sets of
  origins: a parameter, `artifact`, `build`, or `fresh`, a value the walk
  does not see the making of. A literal is made of nothing. Structural
  instructions carry what they read; a pure runtime call carries all its
  arguments (`Argus.EffectModel`), and so do the runtime's
  decompressors, but for a call whose fun only chooses or orders the
  elements of a collection (`Enum.filter/2`, `Enum.sort_by/2`), whose
  result is made of the collection; a read or any other call (a dependency's, an unresolved
  fun's, an apply) is `fresh`, and so are a received message, an
  exception and a stack trace. A local call carries what its callee
  returns of its arguments, and a closure a supported higher-order call
  runs (`ParamFlow.Returns`) what the closure returns of its elements and
  captures. A fun's value is what it captured and what its body returns
  of anything but its own parameters.

  A parameter is then what the module's calls hand it: every local call
  of a function the module neither exports nor makes a fun of by name, a
  closure's captures where it was made, and the elements and accumulator
  of the supported higher-order call that runs it. A parameter of any
  other function, or of a closure no supported call runs, is `fresh`:
  its callers are not all in view. A closure is taken to run where the
  supported call that receives it runs it, as ParamFlow's element flow
  takes it: the same fun also stored or returned, and run elsewhere with
  other arguments, is a known limit.
  """

  @behaviour Argus.Extractor

  alias Argus.EffectModel
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Runtime
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ParamFlow.Returns
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @typedoc "Where a value comes from: a parameter, a BEAM's chunks, the build, or elsewhere."
  @type origin :: {:param, non_neg_integer()} | :artifact | :build | :fresh

  @artifact_reads [
    {:beam_lib, :chunks, 2},
    {:beam_lib, :chunks, 3},
    {:beam_lib, :all_chunks, 1},
    {:code, :get_object_code, 1}
  ]

  @build_dirs [
    {Mix.Project, :manifest_path, 0},
    {Mix.Project, :manifest_path, 1},
    {Mix.Project, :build_path, 0},
    {Mix.Project, :build_path, 1},
    {Mix.Project, :app_path, 0},
    {Mix.Project, :app_path, 1},
    {Mix.Project, :compile_path, 0},
    {Mix.Project, :compile_path, 1}
  ]

  @file_reads [{File, :read, 1}, {File, :read!, 1}, {:file, :read_file, 1}]

  # Byte transformations whose output is made of their input alone, which
  # the effect model leaves unclassified.
  @transforms [
    {:zlib, :uncompress, 1},
    {:zlib, :gunzip, 1},
    {:zlib, :unzip, 1}
  ]

  # Calls that hand back elements of a collection a fun only chooses or
  # orders: the result is made of the collection (and a default), not of
  # what the fun captured. {mfa => the positions the result is made of}.
  @selections %{
    {Enum, :filter, 2} => [0],
    {Enum, :reject, 2} => [0],
    {Enum, :split_with, 2} => [0],
    {Enum, :sort, 2} => [0],
    {Enum, :sort_by, 2} => [0],
    {Enum, :sort_by, 3} => [0],
    {Enum, :uniq_by, 2} => [0],
    {Enum, :dedup_by, 2} => [0],
    {Enum, :take_while, 2} => [0],
    {Enum, :drop_while, 2} => [0],
    {Enum, :find, 2} => [0],
    {Enum, :find, 3} => [0, 1],
    {:lists, :filter, 2} => [1],
    {:lists, :sort, 2} => [1]
  }

  @decoders [{:erlang, :binary_to_term, 1}, {:erlang, :binary_to_term, 2}]

  # What these write comes from outside the function's registers.
  @fresh_ops [:loop_rec, :try_case, :build_stacktrace]

  @impl true
  def relations, do: [:decoded_origin]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions} = module_data) do
    decodes =
      for {:function, name, arity, _entry, instrs} <- functions,
          {instr, idx} <- Enum.with_index(instrs),
          {:ok, m, f, a} <- [Helpers.match_remote_call(instr)],
          {m, f, a} in @decoders,
          do: {InstrId.func_id(mod, name, arity), idx}

    with [_ | _] <- decodes,
         reaching when reaching != nil <- Helpers.reaching(module_data) do
      solved = solve(module_data, reaching)
      params = params(module_data, solved)

      decodes
      |> Enum.flat_map(fn {func, idx} ->
        case Map.fetch(solved, func) do
          {:ok, function} ->
            origins = resolve(input(function, idx, "x0"), func, params)
            row(func, idx, origins)

          :error ->
            []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce(%{}, &add_fact(&2, :decoded_origin, &1))
    else
      _ -> %{}
    end
  end

  defp row(func, idx, origins) do
    cond do
      MapSet.size(origins) == 0 -> []
      not MapSet.subset?(origins, MapSet.new([:artifact, :build])) -> []
      MapSet.member?(origins, :artifact) -> [[InstrId.mint(func, idx), func, "artifact"]]
      true -> [[InstrId.mint(func, idx), func, "build"]]
    end
  end

  # ── Each function ────────────────────────────────────────────────────

  # Per function: its instructions, reads and solved writes, keyed by
  # function ID.
  defp solve(%{module: mod, functions: functions} = module_data, reaching) do
    {targets, callbacks} = Returns.index(module_data)
    reads = ValueFlow.reads_by_function(reaching)

    inputs =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        func = InstrId.func_id(mod, name, arity)
        tuple = List.to_tuple(instrs)
        {func, %{func: func, tuple: tuple, reads: Map.get(reads, func, %{})}}
      end)

    ctx = %{targets: targets, callbacks: callbacks, functions: Map.keys(inputs) |> MapSet.new()}

    Returns.solve(inputs, targets, callbacks, fn function, summaries ->
      solve_function(function, Map.put(ctx, :summaries, summaries))
    end)
  end

  defp solve_function(%{tuple: tuple, reads: reads} = function, ctx) do
    idxs = Enum.to_list(0..(tuple_size(tuple) - 1)//1)

    {outs, nil} =
      ValueFlow.solve(idxs, reads, nil, fn idx, outs, nil ->
        instr = elem(tuple, idx)
        at = fn i -> ValueFlow.inputs(reads, outs, i, &{:param, &1}) end
        inputs = at.(idx)

        writes =
          for reg <- Instr.defs(instr),
              do: {Instr.spell_slot(reg), transfer(instr, idx, reg, inputs, at, function, ctx)}

        {writes, nil, []}
      end)

    function = Map.put(function, :outs, outs)
    function = Map.put(function, :at, fn i -> inputs_at(function, i) end)

    summary =
      Enum.reduce(idxs, MapSet.new(), fn idx, acc ->
        instr = elem(tuple, idx)

        cond do
          instr == :return ->
            MapSet.union(acc, input(function, idx, "x0"))

          Instr.tail_call?(instr) ->
            MapSet.union(acc, call_result(instr, idx, inputs_at(function, idx), function, ctx))

          true ->
            acc
        end
      end)

    {function, summary}
  end

  defp inputs_at(%{reads: reads, outs: outs}, idx),
    do: ValueFlow.inputs(reads, outs, idx, &{:param, &1})

  defp input(function, idx, reg), do: Map.get(inputs_at(function, idx), reg, MapSet.new())

  defp transfer(instr, idx, reg, inputs, at, function, ctx) do
    cond do
      Instr.call?(instr) ->
        call_result(instr, idx, inputs, Map.put(function, :at, at), ctx)

      fresh_op?(instr) ->
        fresh()

      match?({:catch_end, _}, instr) ->
        MapSet.put(Map.get(inputs, "x0", MapSet.new()), :fresh)

      match?({:make_fun3, _, _, _, _, _}, instr) ->
        fun_value(instr, inputs, ctx)

      copy?(instr) ->
        case Helpers.copy_read(instr, Instr.spell_slot(reg)) do
          nil -> MapSet.new()
          read -> Map.get(inputs, read, MapSet.new())
        end

      bif?(instr) ->
        bif_result(instr, inputs)

      true ->
        union(Map.values(inputs))
    end
  end

  defp fresh_op?(instr) when is_tuple(instr), do: elem(instr, 0) in @fresh_ops
  defp fresh_op?(instr), do: instr in @fresh_ops

  defp copy?(instr) when is_tuple(instr), do: elem(instr, 0) in [:move, :fmove, :swap, :trim]
  defp copy?(_instr), do: false

  defp bif?(instr) when is_tuple(instr), do: elem(instr, 0) in [:bif, :gc_bif]
  defp bif?(_instr), do: false

  # A BIF the effect model calls pure is made of its operands; one that
  # reads state (`get/1`) is not.
  defp bif_result(instr, inputs) do
    {name, operands} =
      case instr do
        {:bif, name, _fail, args, _dst} -> {name, args}
        {:gc_bif, name, _fail, _live, args, _dst} -> {name, args}
      end

    if EffectModel.classify(":erlang", Atom.to_string(name), length(operands)) == :pure do
      operands
      |> Enum.map(&Instr.register/1)
      |> Enum.filter(&match?({kind, _} when kind in [:x, :y], &1))
      |> Enum.map(&Map.get(inputs, Instr.spell_slot(&1), MapSet.new()))
      |> union()
    else
      fresh()
    end
  end

  # ── Calls ────────────────────────────────────────────────────────────

  defp call_result(instr, idx, inputs, function, ctx) do
    {:ok, id} = InstrId.parse(InstrId.mint(function.func, idx))
    args = fn n -> for i <- 0..(n - 1)//1, do: Map.get(inputs, "x#{i}", MapSet.new()) end

    cond do
      Map.has_key?(ctx.callbacks, id) ->
        callback_result(Map.fetch!(ctx.callbacks, id), inputs, function, ctx)

      MapSet.member?(ctx.functions, Map.get(ctx.targets, id)) ->
        callee = Map.fetch!(ctx.targets, id)
        substitute(Map.get(ctx.summaries, callee, MapSet.new()), inputs)

      match?({:ok, _, _, _}, Helpers.match_remote_call(instr)) ->
        {:ok, mod, fun, arity} = Helpers.match_remote_call(instr)
        remote_result({mod, fun, arity}, args.(arity))

      true ->
        fresh()
    end
  end

  defp remote_result(mfa, args) do
    cond do
      mfa in @artifact_reads -> MapSet.new([:artifact])
      mfa in @build_dirs -> MapSet.new([:build])
      mfa in @file_reads -> file_contents(args)
      mfa in @transforms -> union(args)
      Map.has_key?(@selections, mfa) -> union(Enum.map(@selections[mfa], &Enum.at(args, &1)))
      pure?(mfa) -> union(args)
      true -> fresh()
    end
  end

  # A file read whole is the build's own when its path is made of a
  # build directory and literals alone: any other part may climb out.
  defp file_contents([path]) do
    if path == MapSet.new([:build]), do: path, else: fresh()
  end

  defp pure?({mod, fun, arity}) do
    Runtime.module?(mod) and
      EffectModel.classify(inspect(mod), Atom.to_string(fun), arity) == :pure
  end

  # A supported higher-order call: its other result sources, and what the
  # closure returns of its arguments and captures. An unresolved fun's
  # result is fresh.
  defp callback_result(%{closure: closure, args: args, base: base}, inputs, function, ctx) do
    base = union(Enum.map(base, &Map.get(inputs, "x#{&1}", MapSet.new())))

    case closure do
      %{target: target, at: creation, first: first, env: env} ->
        if MapSet.member?(ctx.functions, target) do
          captures = function.at.(creation)

          ctx.summaries
          |> Map.get(target, MapSet.new())
          |> Enum.reduce(base, fn
            {:param, p}, acc when p < first ->
              MapSet.union(acc, Map.get(inputs, "x#{Enum.at(args, p)}", MapSet.new()))

            {:param, p}, acc ->
              reg = env |> Enum.at(p - first) |> Instr.spell_slot()
              MapSet.union(acc, Map.get(captures, reg, MapSet.new()))

            origin, acc ->
              MapSet.put(acc, origin)
          end)
        else
          MapSet.put(base, :fresh)
        end

      nil ->
        MapSet.put(base, :fresh)
    end
  end

  # What a fun holds: its captures, and what its body returns of anything
  # but its own parameters.
  defp fun_value({:make_fun3, {m, f, a}, _index, _uniq, _dst, {:list, env}}, inputs, ctx) do
    captured =
      env
      |> Enum.map(&Instr.register/1)
      |> Enum.filter(&match?({kind, _} when kind in [:x, :y], &1))
      |> Enum.map(&Map.get(inputs, Instr.spell_slot(&1), MapSet.new()))
      |> union()

    target = InstrId.func_id(m, f, a)

    body =
      if MapSet.member?(ctx.functions, target),
        do:
          for(
            origin <- Map.get(ctx.summaries, target, MapSet.new()),
            not match?({:param, _}, origin),
            into: MapSet.new(),
            do: origin
          ),
        else: fresh()

    MapSet.union(captured, body)
  end

  defp substitute(summary, inputs) do
    Enum.reduce(summary, MapSet.new(), fn
      {:param, p}, acc -> MapSet.union(acc, Map.get(inputs, "x#{p}", MapSet.new()))
      origin, acc -> MapSet.put(acc, origin)
    end)
  end

  # ── Parameters ───────────────────────────────────────────────────────

  # What each function's parameters are handed, as origins that may name
  # the caller's own parameters: %{{func, k} => [origins()]}. A key
  # absent here is a parameter whose callers are not all in view.
  defp params(%{module: mod, functions: functions} = module_data, solved) do
    open = open(module_data)
    {_targets, callbacks} = Returns.index(module_data)

    local =
      for {:function, name, arity, _entry, instrs} <- functions,
          caller = InstrId.func_id(mod, name, arity),
          {:ok, function} <- [Map.fetch(solved, caller)],
          {instr, idx} <- Enum.with_index(instrs),
          {:ok, ^mod, f, a} <- [Helpers.match_local_call(instr)],
          not MapSet.member?(open, {f, a}),
          k <- 0..(a - 1)//1,
          reduce: %{} do
        acc ->
          key = {InstrId.func_id(mod, f, a), k}
          handed = {caller, input(function, idx, "x#{k}")}
          Map.update(acc, key, [handed], &[handed | &1])
      end

    Enum.reduce(callbacks, local, fn {id, callback}, acc ->
      closure_params(acc, id, callback, solved)
    end)
  end

  # A closure a supported call runs takes the call's arguments in its
  # leading parameters and its captures in the rest. A closure the call
  # resolves to the same function from more than one place has each of
  # them as a caller.
  defp closure_params(
         acc,
         id,
         %{closure: %{target: target, at: creation, first: first, env: env}, args: args},
         solved
       ) do
    caller = InstrId.func_id(id.module, id.func, id.arity)

    case Map.fetch(solved, caller) do
      {:ok, function} ->
        handed =
          Enum.with_index(args, fn source, p -> {p, input(function, id.idx, "x#{source}")} end) ++
            Enum.with_index(env, fn operand, i ->
              {first + i, operand_origins(function, creation, operand)}
            end)

        Enum.reduce(handed, acc, fn {k, origins}, inner ->
          Map.update(inner, {target, k}, [{caller, origins}], &[{caller, origins} | &1])
        end)

      :error ->
        acc
    end
  end

  defp closure_params(acc, _id, _callback, _solved), do: acc

  defp operand_origins(function, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> input(function, at, Instr.spell_slot(reg))
      _literal -> MapSet.new()
    end
  end

  # The functions a caller outside the module's view can run: the
  # exported ones, and those the module makes a fun of by name.
  defp open(%{module: mod, functions: functions} = data) do
    exports = Enum.map(Map.get(data, :exports, []), &export_key/1)

    captured =
      for {:function, _, _, _, instrs} <- functions,
          {:make_fun3, {^mod, f, a}, _, _, _, _} <- instrs,
          not anonymous?(f),
          do: {f, a}

    MapSet.new(exports ++ captured)
  end

  defp export_key({name, arity, _label}), do: {name, arity}
  defp export_key({:atom, name, arity, _label}), do: {name, arity}

  defp anonymous?(name), do: String.starts_with?(Atom.to_string(name), "-")

  # The origins `origins` stand for, once each parameter they name is
  # replaced by what its callers hand it, to a fixpoint. A parameter with
  # no entry in `params` is fresh.
  defp resolve(origins, func, params) do
    resolve([{func, origins}], params, MapSet.new(), MapSet.new())
  end

  defp resolve([], _params, _seen, acc), do: acc

  defp resolve([{func, origins} | rest], params, seen, acc) do
    {acc, more} =
      Enum.reduce(origins, {acc, []}, fn
        {:param, k}, {acc, more} ->
          case Map.fetch(params, {func, k}) do
            {:ok, handed} ->
              if MapSet.member?(seen, {func, k}),
                do: {acc, more},
                else: {acc, handed ++ more}

            :error ->
              {MapSet.put(acc, :fresh), more}
          end

        origin, {acc, more} ->
          {MapSet.put(acc, origin), more}
      end)

    seen =
      Enum.reduce(origins, seen, fn
        {:param, k}, seen -> MapSet.put(seen, {func, k})
        _origin, seen -> seen
      end)

    resolve(more ++ rest, params, seen, acc)
  end

  defp fresh, do: MapSet.new([:fresh])

  defp union(sets), do: Enum.reduce(sets, MapSet.new(), &MapSet.union/2)
end
