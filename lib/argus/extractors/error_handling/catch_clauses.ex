defmodule Argus.Extractors.ErrorHandling.CatchClauses do
  @moduledoc """
  What a `try` handler catches: the classes it tests for, the reason tags
  it discriminates on, and whether some path catches a class outright.

  ## Reading the bytecode

  `{:try, reg, {:f, L}}` installs a handler; the block at `L` begins with
  `{:try_case, reg}`, after which `{x,0}` holds the class (`:error`,
  `:exit`, `:throw`), `{x,1}` the reason and `{x,2}` the stacktrace. The
  clauses of an Elixir `rescue`/`catch` compile to tests on those
  registers: a class test is `is_eq_exact {x,0} :exit`; a reason pattern
  such as `{:noproc, _}` is `is_tagged_tuple {x,1} 2 :noproc`, or an
  `is_eq_exact` on an element pulled out with `get_tuple_element`. A
  clause with no pattern on the reason (`catch :exit, reason ->`,
  `rescue e ->`) tests the class and runs its body. A clause that no
  clause matches falls to a block that re-raises (`bif raise`).

  The walk follows every path from `try_case` — the pass and fail edges of
  each test, every `select_val` arm, jumps and fallthroughs — carrying the
  class the path has established and whether it has tested the reason
  (`{x,1}` or a register copied or projected from it). A path that ends in
  a normal return without having tested the reason catches its class
  outright (`total`); a class established on any such path is a class the
  handler catches. Paths that end in a raise are not catches. Reason tags
  are collected from every atom compared anywhere in the handler region,
  the same over-approximation `callback_tag` makes: a rule asks whether a
  tag is NOT handled, so seeing too many suppresses rather than invents.
  """

  @x0 {:x, 0}
  @x1 {:x, 1}
  @classes [:error, :exit, :throw]

  @typedoc """
  What one handler catches. `classes` and `totals` are among `:error`,
  `:exit`, `:throw` and `:*` (no class test on the path); `tags` are the
  atoms compared in the region; `falls_through` are the tags compared on
  a path that reaches a `case` with no clause for its value — the
  compiler emits such a `case` of its own for `e.field` access, so the
  tags say which `case` it was.
  """
  @type summary :: %{
          classes: [atom()],
          totals: [atom()],
          tags: [atom()],
          falls_through: [atom()]
        }

  @doc "Summarise the handler at `label` of the function `instrs`."
  @spec analyse([tuple()], non_neg_integer()) :: summary()
  def analyse(instrs, label) do
    tuple = List.to_tuple(instrs)
    labels = label_index(instrs)

    case Map.fetch(labels, label) do
      :error ->
        %{classes: [], totals: [], tags: [], falls_through: []}

      {:ok, start} ->
        path = %{class: nil, tested: false, aliases: MapSet.new([@x1]), tags: MapSet.new()}

        acc = %{
          classes: MapSet.new(),
          totals: MapSet.new(),
          tags: MapSet.new(),
          falls_through: MapSet.new()
        }

        {_seen, acc} = walk(start, path, tuple, labels, MapSet.new(), acc)

        %{
          classes: acc.classes |> MapSet.to_list() |> Enum.sort(),
          totals: acc.totals |> MapSet.to_list() |> Enum.sort(),
          tags: acc.tags |> MapSet.to_list() |> Enum.sort(),
          falls_through: acc.falls_through |> MapSet.to_list() |> Enum.sort()
        }
    end
  end

  defp label_index(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {{:label, l}, idx}, acc -> Map.put(acc, l, idx)
      _, acc -> acc
    end)
  end

  # Depth-first from an instruction index; a position is re-entered only
  # with a (class, tested) state it has not been entered with.
  defp walk(idx, path, instrs, labels, seen, acc) do
    key = {idx, path.class, path.tested}

    cond do
      idx >= tuple_size(instrs) -> {seen, acc}
      MapSet.member?(seen, key) -> {seen, acc}
      true -> step(elem(instrs, idx), idx, path, instrs, labels, MapSet.put(seen, key), acc)
    end
  end

  defp next(idx, path, instrs, labels, seen, acc),
    do: walk(idx + 1, path, instrs, labels, seen, acc)

  defp goto(label, path, instrs, labels, seen, acc) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> walk(idx, path, instrs, labels, seen, acc)
      :error -> {seen, acc}
    end
  end

  # ── Class and reason tests ──────────────────────────────────────────

  defp step(
         {:test, :is_eq_exact, {:f, fail}, [a, b]} = instr,
         idx,
         path,
         instrs,
         labels,
         seen,
         acc
       ) do
    {path, acc} = note(path, acc, instr)

    cond do
      reg(a) == @x0 and path.class == nil and class_atom(b) != nil ->
        {seen, acc} = next(idx, %{path | class: class_atom(b)}, instrs, labels, seen, acc)
        goto(fail, path, instrs, labels, seen, acc)

      alias?(a, path) or alias?(b, path) ->
        branch(idx, fail, %{path | tested: true}, instrs, labels, seen, acc)

      true ->
        branch(idx, fail, path, instrs, labels, seen, acc)
    end
  end

  defp step({:test, _op, {:f, fail}, args} = instr, idx, path, instrs, labels, seen, acc)
       when is_list(args) do
    {path, acc} = note(path, acc, instr)
    path = if Enum.any?(args, &alias?(&1, path)), do: %{path | tested: true}, else: path
    branch(idx, fail, path, instrs, labels, seen, acc)
  end

  defp step({:test, _op, {:f, fail}, src, _fields}, idx, path, instrs, labels, seen, acc) do
    path = if alias?(src, path), do: %{path | tested: true}, else: path
    branch(idx, fail, path, instrs, labels, seen, acc)
  end

  defp step(
         {:select_val, src, {:f, default}, {:list, pairs}} = instr,
         _idx,
         path,
         instrs,
         labels,
         seen,
         acc
       ) do
    {path, acc} = note(path, acc, instr)
    arms = Enum.chunk_every(pairs, 2)

    if reg(src) == @x0 and path.class == nil do
      {seen, acc} =
        Enum.reduce(arms, {seen, acc}, fn [val, {:f, l}], {s, a} ->
          goto(l, %{path | class: class_atom(val) || :*}, instrs, labels, s, a)
        end)

      goto(default, path, instrs, labels, seen, acc)
    else
      path = if alias?(src, path), do: %{path | tested: true}, else: path

      {seen, acc} =
        Enum.reduce(arms, {seen, acc}, fn [_val, {:f, l}], {s, a} ->
          goto(l, path, instrs, labels, s, a)
        end)

      goto(default, path, instrs, labels, seen, acc)
    end
  end

  defp step(
         {:select_tuple_arity, src, {:f, default}, {:list, pairs}},
         _idx,
         path,
         instrs,
         labels,
         seen,
         acc
       ) do
    path = if alias?(src, path), do: %{path | tested: true}, else: path

    {seen, acc} =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce({seen, acc}, fn [_val, {:f, l}], {s, a} ->
        goto(l, path, instrs, labels, s, a)
      end)

    goto(default, path, instrs, labels, seen, acc)
  end

  # ── Register flow ───────────────────────────────────────────────────

  defp step({:get_tuple_element, src, _i, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, copy(path, src, dst), instrs, labels, seen, acc)

  defp step({:move, src, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, copy(path, src, dst), instrs, labels, seen, acc)

  # ── Control ─────────────────────────────────────────────────────────

  defp step({:jump, {:f, l}}, _idx, path, instrs, labels, seen, acc),
    do: goto(l, path, instrs, labels, seen, acc)

  defp step({:case_end, _}, _idx, path, _instrs, _labels, seen, acc),
    do: {seen, %{acc | falls_through: MapSet.union(acc.falls_through, path.tags)}}

  defp step({:badmatch, _}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step({:if_end}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step(:if_end, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step({:try_case_end, _}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step(:raw_raise, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step({:raw_raise}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step({:bif, :raise, _, _, _}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}
  defp step({:func_info, _, _, _}, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}

  defp step(:return, _idx, path, _instrs, _labels, seen, acc), do: {seen, caught(acc, path)}

  defp step({call, _arity, _}, _idx, path, _instrs, _labels, seen, acc)
       when call in [:call_only, :call_ext_only],
       do: {seen, caught(acc, path)}

  defp step({call, _arity, _, _}, _idx, path, _instrs, _labels, seen, acc)
       when call in [:call_last, :call_ext_last],
       do: {seen, caught(acc, path)}

  defp step({:apply_last, _, _}, _idx, path, _instrs, _labels, seen, acc),
    do: {seen, caught(acc, path)}

  # A re-raise through the library rather than the opcode ends the path
  # without a catch; any other call clobbers its argument registers.
  defp step({:call_ext, arity, {:extfunc, mod, fun, a}}, idx, path, instrs, labels, seen, acc) do
    if reraise?(mod, fun, a),
      do: {seen, acc},
      else: next(idx, clobber(path, arity), instrs, labels, seen, acc)
  end

  defp step({:call, arity, _}, idx, path, instrs, labels, seen, acc),
    do: next(idx, clobber(path, arity), instrs, labels, seen, acc)

  defp step({:call_fun, arity}, idx, path, instrs, labels, seen, acc),
    do: next(idx, clobber(path, arity + 1), instrs, labels, seen, acc)

  defp step({:call_fun2, _, arity, _}, idx, path, instrs, labels, seen, acc),
    do: next(idx, clobber(path, arity + 1), instrs, labels, seen, acc)

  defp step({:bif, _name, _fail, _args, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step({:gc_bif, _name, _fail, _live, _args, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step({:put_tuple2, dst, _}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step({:put_list, _, _, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step({:get_hd, _, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step({:get_tl, _, dst}, idx, path, instrs, labels, seen, acc),
    do: next(idx, forget(path, dst), instrs, labels, seen, acc)

  defp step(
         {:get_map_elements, {:f, fail}, src, {:list, kvs}},
         idx,
         path,
         instrs,
         labels,
         seen,
         acc
       ) do
    path = if alias?(src, path), do: %{path | tested: true}, else: path
    path = kvs |> Enum.drop_every(2) |> Enum.reduce(path, &forget(&2, &1))
    branch(idx, fail, path, instrs, labels, seen, acc)
  end

  defp step(_instr, idx, path, instrs, labels, seen, acc),
    do: next(idx, path, instrs, labels, seen, acc)

  defp branch(idx, fail, path, instrs, labels, seen, acc) do
    {seen, acc} = next(idx, path, instrs, labels, seen, acc)
    goto(fail, path, instrs, labels, seen, acc)
  end

  # ── Path state ──────────────────────────────────────────────────────

  defp caught(acc, path) do
    class = path.class || :*
    acc = %{acc | classes: MapSet.put(acc.classes, class)}
    if path.tested, do: acc, else: %{acc | totals: MapSet.put(acc.totals, class)}
  end

  defp copy(path, src, dst) do
    if alias?(src, path),
      do: %{path | aliases: MapSet.put(path.aliases, reg(dst))},
      else: forget(path, dst)
  end

  defp forget(path, dst) do
    case reg(dst) do
      nil -> path
      r -> %{path | aliases: MapSet.delete(path.aliases, r)}
    end
  end

  defp clobber(path, arity) when arity > 0,
    do: Enum.reduce(0..(arity - 1), path, &forget(&2, {:x, &1}))

  defp clobber(path, _arity), do: path

  defp alias?(operand, path) do
    case reg(operand) do
      nil -> false
      r -> MapSet.member?(path.aliases, r)
    end
  end

  defp reraise?(:erlang, :raise, 3), do: true
  defp reraise?(:erlang, :error, a) when a in [1, 2], do: true
  defp reraise?(:erlang, :exit, 1), do: true
  defp reraise?(:erlang, :throw, 1), do: true
  defp reraise?(_mod, _fun, _arity), do: false

  # ── Tags ────────────────────────────────────────────────────────────

  # Every atom an instruction compares against, class atoms excluded —
  # recorded for the handler and carried on the path.
  defp note(path, acc, instr) do
    atoms = compared_atoms(instr)

    {%{path | tags: Enum.reduce(atoms, path.tags, &MapSet.put(&2, &1))},
     %{acc | tags: Enum.reduce(atoms, acc.tags, &MapSet.put(&2, &1))}}
  end

  defp compared_atoms({:test, :is_eq_exact, _f, [a, b]}), do: atoms([a, b])
  defp compared_atoms({:test, :is_ne_exact, _f, [a, b]}), do: atoms([a, b])
  defp compared_atoms({:test, :is_tagged_tuple, _f, [_src, _arity, tag]}), do: atoms([tag])

  defp compared_atoms({:select_val, _src, _f, {:list, pairs}}),
    do: atoms(Enum.take_every(pairs, 2))

  defp compared_atoms(_instr), do: []

  defp atoms(operands) do
    for {:atom, a} <- operands, a not in @classes, a not in [true, false, nil], do: a
  end

  defp class_atom({:atom, c}) when c in @classes, do: c
  defp class_atom(_), do: nil

  defp reg({:tr, r, _type}), do: reg(r)
  defp reg({:x, _} = r), do: r
  defp reg({:y, _} = r), do: r
  defp reg(_), do: nil
end
