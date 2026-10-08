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
  are the atoms compared along a catching path, recorded against that
  path's class — so `catch :exit, {:noproc, _}` yields the pair
  `{:exit, :noproc}` and nothing for `:error`. Within one clause the
  atoms its body compares count too (a `case` in the body), the same
  over-approximation `callback_tag` makes: a rule asks whether a tag is
  NOT handled, so seeing too many suppresses rather than invents.

  Some of those atoms head the reason, a tuple the clause tests for
  (`tuple_tags`): an `is_tagged_tuple` of the reason, or a comparison on
  a register holding the reason's first element. `catch :exit, {:noproc,
  _}` yields `:noproc` in both; `catch :exit, :noproc` compares the
  reason itself and yields it only as a tag. The two catch different
  exits — a `GenServer.call` to a dead process exits with `{:noproc,
  {GenServer, :call, _}}`, a `GenServer.stop` with bare `:noproc` — so a
  rule that asks about one reads the right set. An atom that heads the
  reason's first element, itself a tuple, is an `inner_tags` one:
  `catch :exit, {{:shutdown, _}, _}` yields `:shutdown` there, and none
  in `tuple_tags`. A call whose peer stops with `{:shutdown, reason}`
  exits with that shape, and one whose peer stops with `:shutdown` with
  `{:shutdown, _}`: the walk keeps, per register, where in the reason
  its value sits, so the two are told apart.

  A clause that takes the reason by its shape alone, a tuple whose
  elements it never compares (`catch exit:{Reason, _}`), is
  `open_tuples`: it catches every tuple reason of its class, whatever
  the tag, `{:shutdown, _}` and `{:normal, _}` among them — when it
  keeps what it catches. A path that re-raises in tail position (`exit:
  {Reason, _} -> exit(Reason)`) takes nothing: no tag, no tuple and no
  class outright. And a tag the path passed an inequality with (`when
  Reason =/= shutdown`, or the other side of an earlier clause's test)
  is one it does not take: an open clause counts only when another
  catching path takes each tag it excluded.

  An Elixir `rescue X` tests the reason's `__struct__` (a `map_get`
  before `Exception.normalize/3`); the register that read holds is
  treated as a projection of the reason, so the clause counts as tested
  and `X` is its tag.
  """

  alias Argus.Instr
  import Argus.Instr, only: [slot: 1]

  @x0 {:x, 0}
  @x1 {:x, 1}
  @classes [:error, :exit, :throw]

  # Tests of a term's type or size, which take a reason by its shape
  # alone; every other test compares it with a value.
  @shape_tests [
    :is_tuple,
    :test_arity,
    :is_atom,
    :is_binary,
    :is_bitstr,
    :is_integer,
    :is_float,
    :is_number,
    :is_list,
    :is_nonempty_list,
    :is_nil,
    :is_map,
    :is_pid,
    :is_port,
    :is_reference,
    :is_function,
    :is_function2,
    :is_boolean
  ]
  @tuple_tests [:is_tuple, :test_arity]

  @typedoc """
  What one handler catches. `classes` and `totals` are among `:error`,
  `:exit`, `:throw` and `:*` (no class test on the path); `tags` are
  `{class, atom}` pairs, the atoms compared along a path that catches
  that class, and `tuple_tags` those of them compared as the reason's
  first element (the reason a tuple), `inner_tags` those compared as the
  first element of the reason's first element; `falls_through` are the
  tags compared on
  a path that reaches a `case` with no clause for its value — the
  compiler emits such a `case` of its own for `e.field` access, so the
  tags say which `case` it was. `handled` are the classes established
  on a catching path that ends in a return rather than a re-raise in
  tail position: what the handler keeps from propagating. A clause that
  unwraps the reason and re-raises it catches its class, but handles
  nothing.
  """
  @type summary :: %{
          classes: [atom()],
          totals: [atom()],
          tags: [{atom(), atom()}],
          tuple_tags: [{atom(), atom()}],
          inner_tags: [{atom(), atom()}],
          open_tuples: [atom()],
          falls_through: [atom()],
          handled: [atom()],
          visited: [non_neg_integer()],
          last: non_neg_integer() | nil
        }

  @doc "Summarise the handler at `label` of the function `instrs`."
  @spec analyse([tuple()], non_neg_integer()) :: summary()
  def analyse(instrs, label) do
    tuple = List.to_tuple(instrs)
    labels = label_index(instrs)

    case Map.fetch(labels, label) do
      :error ->
        %{
          classes: [],
          totals: [],
          tags: [],
          tuple_tags: [],
          inner_tags: [],
          open_tuples: [],
          falls_through: [],
          handled: [],
          visited: [],
          last: nil
        }

      {:ok, start} ->
        path = new_path()
        acc = new_acc(start)

        {seen, acc} = walk(start, path, tuple, labels, MapSet.new(), acc)

        # `visited` is every instruction the handler runs, `last` the
        # furthest: what a span that covers the whole catch is drawn from.
        %{
          classes: acc.classes |> MapSet.to_list() |> Enum.sort(),
          totals: acc.totals |> MapSet.to_list() |> Enum.sort(),
          tags: acc.tags |> MapSet.to_list() |> Enum.sort(),
          tuple_tags: acc.tuple_tags |> MapSet.to_list() |> Enum.sort(),
          inner_tags: acc.inner_tags |> MapSet.to_list() |> Enum.sort(),
          open_tuples: open_tuples(acc),
          falls_through: acc.falls_through |> MapSet.to_list() |> Enum.sort(),
          handled: acc.handled |> MapSet.to_list() |> Enum.sort(),
          visited: seen |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(),
          last: acc.last
        }
    end
  end

  @doc """
  Every instruction index reachable from `start` along the function's
  control flow: the same walk as `analyse/2` from an arbitrary point.
  Subtracting it from a handler's `visited`, starting after the try's
  `try_end`, leaves the handler's own instructions — the code after the
  `try` expression is reached from both.
  """
  @spec reach([tuple()], non_neg_integer()) :: [non_neg_integer()]
  def reach(instrs, start) do
    tuple = List.to_tuple(instrs)
    labels = label_index(instrs)
    {seen, _acc} = walk(start, new_path(), tuple, labels, MapSet.new(), new_acc(start))
    seen |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
  end

  # `paths` are the registers holding the reason (`[]`) or a projection
  # of it, each with where in the reason it sits: the element positions
  # `get_tuple_element` took, down from the reason (`[0]`, its first
  # element). A register at `p ++ [0]` holds the first element of the
  # tuple at `p`, what a comparison against that tuple's tag reads.
  # `valued` is whether the path compared the reason, or a part of it,
  # with a value; `tuple` whether it established the reason is a tuple.
  defp new_path do
    %{
      class: nil,
      tested: false,
      valued: false,
      tuple: false,
      aliases: MapSet.new([@x1]),
      paths: %{@x1 => []},
      tags: MapSet.new(),
      tuple_tags: MapSet.new(),
      inner_tags: MapSet.new(),
      excluded: MapSet.new()
    }
  end

  defp new_acc(start) do
    %{
      classes: MapSet.new(),
      totals: MapSet.new(),
      tags: MapSet.new(),
      tuple_tags: MapSet.new(),
      inner_tags: MapSet.new(),
      open_tuples: MapSet.new(),
      falls_through: MapSet.new(),
      handled: MapSet.new(),
      last: start
    }
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
  # with a (class, tested, valued, tuple) state it has not been entered
  # with.
  defp walk(idx, path, instrs, labels, seen, acc) do
    key = {idx, path.class, path.tested, path.valued, path.tuple}

    cond do
      idx >= tuple_size(instrs) ->
        {seen, acc}

      MapSet.member?(seen, key) ->
        {seen, acc}

      true ->
        acc = %{acc | last: max(acc.last, idx)}
        step(elem(instrs, idx), idx, path, instrs, labels, MapSet.put(seen, key), acc)
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
      slot(a) == @x0 and path.class == nil and class_atom(b) != nil ->
        # The clause begins here: the atoms compared before it belong to
        # the dispatch, not to this clause.
        clause = %{
          path
          | class: class_atom(b),
            tags: MapSet.new(),
            tuple_tags: MapSet.new(),
            inner_tags: MapSet.new(),
            excluded: MapSet.new()
        }

        {seen, acc} = next(idx, clause, instrs, labels, seen, acc)
        goto(fail, path, instrs, labels, seen, acc)

      alias?(a, path) or alias?(b, path) ->
        # Only the equal side is the compared value; the other side is
        # every other one, as open as before the test, less the value.
        tested = %{path | tested: true}

        branch(
          idx,
          fail,
          %{tested | valued: true},
          exclude(tested, instr),
          instrs,
          labels,
          seen,
          acc
        )

      true ->
        branch(idx, fail, path, instrs, labels, seen, acc)
    end
  end

  defp step({:test, op, {:f, fail}, args} = instr, idx, path, instrs, labels, seen, acc)
       when is_list(args) do
    {path, acc} = note(path, acc, instr)

    if Enum.any?(args, &alias?(&1, path)) do
      tested = %{path | tested: true}

      # A value test constrains the side where it holds (the unequal side
      # of `is_ne_exact`); a shape test constrains nothing a value would.
      {pass, failed} =
        cond do
          op in @shape_tests ->
            shaped = %{
              tested
              | tuple: path.tuple or (op in @tuple_tests and slot(hd(args)) == @x1)
            }

            {shaped, tested}

          op in [:is_ne_exact, :is_ne] ->
            {exclude(tested, instr), %{tested | valued: true}}

          true ->
            {%{tested | valued: true}, exclude(tested, instr)}
        end

      branch(idx, fail, pass, failed, instrs, labels, seen, acc)
    else
      branch(idx, fail, path, instrs, labels, seen, acc)
    end
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
    arms = Enum.chunk_every(pairs, 2)

    if slot(src) == @x0 and path.class == nil do
      {seen, acc} =
        Enum.reduce(arms, {seen, acc}, fn [val, {:f, l}], {s, a} ->
          clause = %{
            path
            | class: class_atom(val) || :*,
              tags: MapSet.new(),
              tuple_tags: MapSet.new(),
              inner_tags: MapSet.new(),
              excluded: MapSet.new()
          }

          goto(l, clause, instrs, labels, s, a)
        end)

      goto(default, path, instrs, labels, seen, acc)
    else
      # Each arm is the reason equal to its own value: the path to it
      # compares that value alone. The default is every other value, and
      # takes none of the arms'.
      {arm_path, default_path} =
        if alias?(src, path),
          do: {%{path | tested: true, valued: true}, exclude(%{path | tested: true}, instr)},
          else: {path, path}

      # Arms sharing a target are one path there (the walk enters a
      # position once per state): it compares all their values.
      {seen, acc} =
        arms
        |> Enum.group_by(fn [_val, {:f, l}] -> l end, fn [val, _] -> val end)
        |> Enum.sort()
        |> Enum.reduce({seen, acc}, fn {l, vals}, {s, a} ->
          list = Enum.flat_map(vals, &[&1, {:f, l}])
          {arm, a} = note(arm_path, a, {:select_val, src, {:f, default}, {:list, list}})
          goto(l, arm, instrs, labels, s, a)
        end)

      {default_path, acc} =
        if alias?(src, path), do: {default_path, acc}, else: note(default_path, acc, instr)

      goto(default, default_path, instrs, labels, seen, acc)
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
    path =
      if alias?(src, path),
        do: %{path | tested: true, tuple: path.tuple or slot(src) == @x1},
        else: path

    {seen, acc} =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce({seen, acc}, fn [_val, {:f, l}], {s, a} ->
        goto(l, path, instrs, labels, s, a)
      end)

    goto(default, path, instrs, labels, seen, acc)
  end

  # ── Register flow ───────────────────────────────────────────────────

  # A projection of the reason — an element of it, or the `__struct__` an
  # Elixir `rescue X` reads before normalizing — is the reason as far as
  # testing it goes, so these copy the alias where Argus.Instr would say
  # the destination holds a new value.
  defp step({:get_tuple_element, src, i, dst}, idx, path, instrs, labels, seen, acc) do
    next(idx, copy(path, src, dst, i), instrs, labels, seen, acc)
  end

  defp step(
         {:bif, :map_get, _fail, [{:atom, :__struct__}, src], dst},
         idx,
         path,
         instrs,
         labels,
         seen,
         acc
       ),
       do: next(idx, copy(path, src, dst, :__struct__), instrs, labels, seen, acc)

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

  # The handler's first instruction writes the class, reason and
  # stacktrace the walk starts out knowing are there.
  defp step({:try_case, _reg}, idx, path, instrs, labels, seen, acc),
    do: next(idx, path, instrs, labels, seen, acc)

  # ── Control ─────────────────────────────────────────────────────────

  defp step({:case_end, _}, _idx, path, _instrs, _labels, seen, acc),
    do: {seen, %{acc | falls_through: MapSet.union(acc.falls_through, path.tags)}}

  # `raw_raise` returns `badarg` instead of raising only for an invalid
  # class, and a handler re-raises the class `try_case` gave it, which is
  # always valid: here it ends the path without a catch.
  defp step(:raw_raise, _idx, _path, _instrs, _labels, seen, acc), do: {seen, acc}

  # A re-raise through the library rather than the opcode ends the path
  # without a catch. One in tail position is how a clause that unwraps
  # the reason re-raises what it found (`reraise original, stacktrace`):
  # that clause handles its class, and the path counts as a catch.
  defp step(instr, idx, path, instrs, labels, seen, acc) do
    cond do
      reraise?(instr) ->
        {seen, acc}

      Instr.exits?(instr) ->
        reraise = tail_reraise?(instr)
        {seen, handled(reraise, caught(acc, path, reraise), path)}

      true ->
        path = %{
          path
          | aliases: MapSet.new(Instr.carry(instr, path.aliases)),
            paths: carry_paths(instr, path.paths)
        }

        {seen, acc} =
          if Instr.falls_through?(instr),
            do: next(idx, path, instrs, labels, seen, acc),
            else: {seen, acc}

        instr
        |> Instr.targets()
        |> Enum.reduce({seen, acc}, fn label, {s, a} ->
          goto(label, path, instrs, labels, s, a)
        end)
    end
  end

  defp branch(idx, fail, path, instrs, labels, seen, acc),
    do: branch(idx, fail, path, path, instrs, labels, seen, acc)

  defp branch(idx, fail, pass, failed, instrs, labels, seen, acc) do
    {seen, acc} = next(idx, pass, instrs, labels, seen, acc)
    goto(fail, failed, instrs, labels, seen, acc)
  end

  # ── Path state ──────────────────────────────────────────────────────

  # A path that ends the handler. One that re-raises in tail position
  # (`exit(reason)` after `:exit, {reason, _}`, a `reraise`) catches its
  # class and hands every reason on: it takes no tag, no tuple and no
  # class outright, and the caller dies of what it re-raised. Tags the
  # path passed an inequality with (`when reason != :shutdown`, the
  # other side of `{:noproc, _} ->`) are the ones it does not take.
  defp caught(acc, path, reraise) do
    class = path.class || :*
    acc = %{acc | classes: MapSet.put(acc.classes, class)}

    # A re-raising path still discriminates the tags it compares (the
    # erpc rule asks which error shapes a handler tells apart before it
    # re-raises); an exit it hands on is taken by nobody.
    if reraise do
      if class == :exit,
        do: acc,
        else: %{acc | tags: Enum.reduce(path.tags, acc.tags, &MapSet.put(&2, {class, &1}))}
    else
      pairs = for t <- path.tags, not MapSet.member?(path.excluded, t), do: {class, t}
      tuple_pairs = for t <- path.tuple_tags, not MapSet.member?(path.excluded, t), do: {class, t}
      inner_pairs = for t <- path.inner_tags, not MapSet.member?(path.excluded, t), do: {class, t}

      acc = %{
        acc
        | tags: Enum.reduce(pairs, acc.tags, &MapSet.put(&2, &1)),
          tuple_tags: Enum.reduce(tuple_pairs, acc.tuple_tags, &MapSet.put(&2, &1)),
          inner_tags: Enum.reduce(inner_pairs, acc.inner_tags, &MapSet.put(&2, &1))
      }

      acc =
        if path.tested and path.tuple and not path.valued,
          do: %{acc | open_tuples: MapSet.put(acc.open_tuples, {class, path.excluded})},
          else: acc

      if path.tested, do: acc, else: %{acc | totals: MapSet.put(acc.totals, class)}
    end
  end

  # A clause open to every tuple of its class but the ones it excluded
  # takes every tuple when another catching path takes each excluded one
  # (`{:noproc, _} -> a; {reason, _} -> b`, brod's safe_gen_call); not
  # when an excluded one goes nowhere (`{reason, _} when reason !=
  # :shutdown`).
  defp open_tuples(acc) do
    for {class, excluded} <- acc.open_tuples,
        Enum.all?(excluded, fn t ->
          MapSet.member?(acc.tags, {class, t}) or MapSet.member?(acc.tuple_tags, {class, t})
        end),
        uniq: true do
      class
    end
    |> Enum.sort()
  end

  # The atoms `instr` compares, on the side of it where the reason is
  # none of them.
  defp exclude(path, instr),
    do: %{path | excluded: Enum.reduce(compared_atoms(instr), path.excluded, &MapSet.put(&2, &1))}

  # `dst` takes the projection `step` of `src`: an element position, or
  # `:__struct__`.
  defp copy(path, src, dst, step) do
    case {Map.fetch(path.paths, slot(src)), alias?(src, path)} do
      {{:ok, at}, true} ->
        %{
          path
          | aliases: MapSet.put(path.aliases, slot(dst)),
            paths: Map.put(path.paths, slot(dst), at ++ [step])
        }

      {:error, true} ->
        %{
          path
          | aliases: MapSet.put(path.aliases, slot(dst)),
            paths: Map.delete(path.paths, slot(dst))
        }

      {_, false} ->
        forget(path, dst)
    end
  end

  defp forget(path, dst) do
    case slot(dst) do
      nil -> path
      r -> %{path | aliases: MapSet.delete(path.aliases, r), paths: Map.delete(path.paths, r)}
    end
  end

  # Where each register sits in the reason after `instr`: a register it
  # writes keeps a place only when it copied one there (Instr.carry's
  # reading), from the register it copied.
  defp carry_paths(instr, paths) do
    holding = Map.keys(paths)
    after_instr = Instr.carry(instr, holding)

    for r <- after_instr, into: %{} do
      case Instr.copy_source(instr, r) do
        src when is_map_key(paths, src) -> {r, Map.fetch!(paths, src)}
        _ -> {r, Map.fetch!(paths, r)}
      end
    end
  end

  defp alias?(operand, path) do
    case slot(operand) do
      nil -> false
      r -> MapSet.member?(path.aliases, r)
    end
  end

  defp handled(true, acc, _path), do: acc
  defp handled(false, acc, path), do: %{acc | handled: MapSet.put(acc.handled, path.class || :*)}

  defp tail_reraise?({:call_ext_only, _arity, {:extfunc, mod, fun, a}}), do: reraise?(mod, fun, a)

  defp tail_reraise?({:call_ext_last, _arity, {:extfunc, mod, fun, a}, _}),
    do: reraise?(mod, fun, a)

  defp tail_reraise?(_instr), do: false

  defp reraise?({:call_ext, _arity, {:extfunc, mod, fun, a}}), do: reraise?(mod, fun, a)
  defp reraise?(_instr), do: false

  defp reraise?(:erlang, :raise, 3), do: true
  defp reraise?(:erlang, :error, a) when a in [1, 2], do: true
  defp reraise?(:erlang, :exit, 1), do: true
  defp reraise?(:erlang, :throw, 1), do: true
  defp reraise?(_mod, _fun, _arity), do: false

  # ── Tags ────────────────────────────────────────────────────────────

  # Every atom an instruction compares against, class atoms excluded —
  # carried on the path and attributed to its clause when the path ends
  # in a catch.
  defp note(path, acc, instr) do
    atoms = compared_atoms(instr)
    {tuple, inner} = compared_heads(instr, path)

    {%{
       path
       | tags: Enum.reduce(atoms, path.tags, &MapSet.put(&2, &1)),
         tuple_tags: Enum.reduce(tuple, path.tuple_tags, &MapSet.put(&2, &1)),
         inner_tags: Enum.reduce(inner, path.inner_tags, &MapSet.put(&2, &1))
     }, acc}
  end

  # The atoms an instruction compares as the first element of the reason
  # and of the reason's first element: the tag of an `is_tagged_tuple` of
  # either, or a comparison on a register holding its first element.
  defp compared_heads({:test, :is_tagged_tuple, _f, [src, _arity, tag]}, path),
    do: headed(place(src, path), atoms([tag]))

  # A comparison with a literal tuple headed by an atom compares that
  # atom as the head of the tuple at the operand's place (`{{:shutdown,
  # :removed}, _}` compares the reason's first element with the literal
  # whole): taken as the clause's, over-approximated as `catch_tag` is.
  defp compared_heads({:test, op, _f, [a, b]}, path) when op in [:is_eq_exact, :is_ne_exact] do
    cond do
      head_of(a, path) != nil ->
        headed(head_of(a, path), atoms([b]))

      head_of(b, path) != nil ->
        headed(head_of(b, path), atoms([a]))

      literal_head(b) != nil and place(a, path) != nil ->
        headed(place(a, path), [literal_head(b)])

      literal_head(a) != nil and place(b, path) != nil ->
        headed(place(b, path), [literal_head(a)])

      true ->
        {[], []}
    end
  end

  defp compared_heads({:select_val, src, _f, {:list, pairs}}, path),
    do: headed(head_of(src, path), atoms(Enum.take_every(pairs, 2)))

  defp compared_heads(_instr, _path), do: {[], []}

  defp literal_head({:literal, tuple}) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    case elem(tuple, 0) do
      atom when is_atom(atom) and atom not in @classes and atom not in [true, false, nil] -> atom
      _ -> nil
    end
  end

  defp literal_head(_operand), do: nil

  defp headed([], atoms), do: {atoms, []}
  defp headed([0], atoms), do: {[], atoms}
  defp headed(_place, _atoms), do: {[], []}

  # Where in the reason the operand's value sits, or nil.
  defp place(operand, path) do
    case slot(operand) do
      nil -> nil
      r -> Map.get(path.paths, r)
    end
  end

  # The tuple whose first element the operand holds, by its place in the
  # reason, or nil.
  defp head_of(operand, path) do
    case place(operand, path) do
      [_ | _] = at -> if List.last(at) == 0, do: Enum.drop(at, -1)
      _ -> nil
    end
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
end
