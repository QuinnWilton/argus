defmodule Argus.Extractors.GenStatem.CallClauses do
  @moduledoc """
  `{:call, from}` clauses that return without answering the caller.

  A gen_statem answers a call with a `{:reply, from, value}` action, by
  postponing the event, or by keeping `from` in its data to reply later.
  A clause that does none of those and returns `:keep_state_and_data` (or
  a state tuple without actions) leaves the caller blocked — for the
  default `:infinity` of `:gen_statem.call/2`, forever. Finch's HTTP/2
  pool did exactly that for a cancel while disconnected (sneako/finch#213).

  ## Reading the bytecode

  The event type is `{x, 0}`; a call clause's head tests
  `is_tagged_tuple {x,0} 2 :call`. From the success edge of that test the
  walk follows every path to a return, path-sensitively: it carries
  whether the path has replied (a `:reply` action built, `:postpone`
  named, `:gen_statem.reply/2` called) and whether `from` — read with
  `get_tuple_element {x,0} 1` — has been handed to anything else (put
  into a map, tuple or list, passed to a call), which counts as kept. A
  test on `{x,0}` other than the call tag is another event type's clause
  and ends the path. A return of the bare atom `:keep_state_and_data`, or
  of a `{:keep_state, data}` / `{:next_state, state, data}` /
  `{:repeat_state, data}` tuple with no actions element, on a path that
  neither replied nor kept `from`, is an unreplied call.

  The site reported is the last pattern test the path passed on its way
  in, not the return: the compiler shares one `:keep_state_and_data`
  return block between clauses, and its line is whatever preceded it.
  The Line chunk cannot name the clause either — pattern tests carry the
  previous clause's line — so the literal that test compares against
  (`:cancel` in `{:cancel, _ref}`) rides along, for a consumer with the
  source to find the clause head by.
  """

  alias Argus.Cfg.{Block, Function}
  import Argus.Instr, only: [slot: 1]

  @x0 {:x, 0}
  @stateful_tags %{keep_state: 2, next_state: 3, repeat_state: 2}

  @doc """
  Each clause that leaves a call unanswered: the instruction index of its
  last pattern test (its return, when the path passed none) and the
  literal that test compares against, `""` when it has none.
  """
  @spec analyse(Function.t() | nil, [tuple()]) :: [{non_neg_integer(), String.t()}]
  def analyse(nil, _instrs), do: []

  def analyse(%Function{} = fun, instrs) do
    tuple = List.to_tuple(instrs)

    fun.blocks
    |> Map.values()
    |> Enum.flat_map(&call_heads(&1, tuple))
    |> Enum.uniq()
    |> Enum.flat_map(fn {block_id, from} ->
      walk(
        block_id,
        %{replied: false, kept: false, from: from, event: [@x0], x0: nil, head: nil, tag: ""},
        fun,
        tuple,
        %{},
        []
      )
      |> elem(1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The block that dispatches on the event type, and where the call arm
  # continues. Two shapes: a clause head testing `is_tagged_tuple {x,0}
  # 2 :call` directly (its pass edge), and the compiler's usual dispatch —
  # `get_tuple_element {x,0} 0` into a register, then `select_val` on it
  # (the `:call` arm) or `is_eq_exact` against `:call` (the pass edge).
  # `from` is `get_tuple_element {x,0} 1`, usually read in that same
  # dispatch block, so the registers it landed in seed the path.
  defp call_heads(%Block{range: {first, last}, succs: succs}, instrs) do
    body = for idx <- first..last, do: elem(instrs, idx)
    tags = for {:get_tuple_element, src, 0, dst} <- body, slot(src) == @x0, do: slot(dst)
    from = for {:get_tuple_element, src, 1, dst} <- body, slot(src) == @x0, do: slot(dst)

    for to <- call_arm_targets(elem(instrs, last), tags, succs), do: {to, from}
  end

  defp call_arm_targets({:test, :is_tagged_tuple, _f, _args} = instr, _tags, succs) do
    if call_head?(instr), do: for({to, :branch_pass} <- succs, do: to), else: []
  end

  defp call_arm_targets({:test, :is_eq_exact, _f, [a, b]}, tags, succs) do
    if compares_tag_to_call?(a, b, tags), do: for({to, :branch_pass} <- succs, do: to), else: []
  end

  defp call_arm_targets({:select_val, src, _f, _list}, tags, succs) do
    if slot(src) in tags, do: for({to, {:select_arm, ":call"}} <- succs, do: to), else: []
  end

  defp call_arm_targets(_instr, _tags, _succs), do: []

  defp compares_tag_to_call?(a, b, tags),
    do:
      (slot(a) in tags and literal_atom(b) == :call) or
        (slot(b) in tags and literal_atom(a) == :call)

  # Depth-first over blocks with the path state; a block is revisited only
  # with a state it has not been entered with (the state is finite, so the
  # walk is).
  defp walk(block_id, path, fun, instrs, seen, found) do
    # The alias sets are part of the state: a block re-entered with
    # `from` in a different register is a different path, and pruning it
    # would lose a later "kept" observation.
    key = {block_id, path.replied, path.kept, Enum.sort(path.from), Enum.sort(path.event)}

    if Map.has_key?(seen, key) do
      {seen, found}
    else
      seen = Map.put(seen, key, true)
      %Block{range: {first, last}} = block = Map.fetch!(fun.blocks, block_id)

      {path, found, stop?} =
        Enum.reduce_while(first..last, {path, found, false}, fn idx, {p, f, _} ->
          case step(elem(instrs, idx), idx, p) do
            {:continue, p} -> {:cont, {p, f, false}}
            {:unreplied, p} -> {:cont, {p, [{p.head || idx, p.tag} | f], false}}
            :stop -> {:halt, {p, f, true}}
          end
        end)

      if stop? do
        {seen, found}
      else
        Enum.reduce(block.succs, {seen, found}, fn {to, kind}, {s, f} ->
          if follow?(elem(instrs, last), kind),
            do: walk(to, entered(path, kind, last, elem(instrs, last)), fun, instrs, s, f),
            else: {s, f}
        end)
      end
    end
  end

  # A pass edge or a select arm is a pattern test this clause passed; the
  # last one before the return is the clause's head, and the literal it
  # compares against names the clause.
  defp entered(path, :branch_pass, idx, instr),
    do: %{path | head: idx, tag: test_literal(instr) || path.tag}

  defp entered(path, {:select_arm, lit}, idx, _instr), do: %{path | head: idx, tag: lit}
  defp entered(path, _kind, _idx, _instr), do: path

  defp test_literal({:test, :is_tagged_tuple, _f, [_src, _arity, {:atom, a}]}), do: inspect(a)

  defp test_literal({:test, :is_eq_exact, _f, [a, b]}) do
    case literal_atom(a) || literal_atom(b) do
      nil -> nil
      atom -> inspect(atom)
    end
  end

  defp test_literal(_instr), do: nil

  # ── One instruction along a path ────────────────────────────────────

  # `from` is element 1 of the event, read from {x,0} or from a register
  # the event was saved to (a clause with a multi-line body keeps it in
  # a y register and reads `from` from there).
  defp step({:get_tuple_element, src, 1, dst}, _idx, path) do
    if slot(src) in path.event,
      do: {:continue, %{forget(path, dst) | from: [slot(dst) | path.from]}},
      else: {:continue, forget(path, dst)}
  end

  defp step({:move, src, dst}, _idx, path) do
    cond do
      slot(src) in path.from ->
        {:continue, %{forget(path, dst) | from: [slot(dst) | path.from]}}

      slot(src) in path.event ->
        {:continue, %{forget(path, dst) | event: [slot(dst) | path.event]}}

      literal_atom(src) == :postpone ->
        {:continue, %{path | replied: true}}

      slot(dst) == @x0 and literal_atom(src) == :keep_state_and_data ->
        {:continue, %{forget(path, dst) | x0: :bare}}

      true ->
        {:continue, forget(path, dst)}
    end
  end

  defp step({:call_ext, _arity, {:extfunc, mod, :reply, 2}}, _idx, path)
       when mod in [:gen_statem, GenStateMachine],
       do: {:continue, %{path | replied: true}}

  defp step({:put_tuple2, dst, {:list, [head | rest]}}, _idx, path) do
    cond do
      literal_atom(head) == :reply ->
        {:continue, forget(%{path | replied: true}, dst)}

      # `from` anywhere in the tuple, its head included: `{from, expected}`.
      uses_from?([head | rest], path) ->
        {:continue, forget(%{path | kept: true}, dst)}

      slot(dst) == @x0 and Map.get(@stateful_tags, literal_atom(head)) == length(rest) + 1 ->
        # A state tuple of exactly the arity that carries no actions.
        {:continue, %{forget(path, dst) | x0: :bare}}

      true ->
        {:continue, forget(path, dst)}
    end
  end

  defp step({:put_list, head, tail, dst}, _idx, path) do
    cond do
      literal_atom(head) == :postpone -> {:continue, forget(%{path | replied: true}, dst)}
      uses_from?([head, tail], path) -> {:continue, forget(%{path | kept: true}, dst)}
      true -> {:continue, forget(path, dst)}
    end
  end

  defp step({op, _fail, src, dst, _live, {:list, kvs}}, _idx, path)
       when op in [:put_map_assoc, :put_map_exact] do
    if uses_from?([src | kvs], path),
      do: {:continue, forget(%{path | kept: true}, dst)},
      else: {:continue, forget(path, dst)}
  end

  defp step({call, arity, _}, _idx, path) when call in [:call, :call_ext] do
    path = %{path | x0: nil}

    if Enum.any?(0..(arity - 1)//1, &({:x, &1} in path.from)),
      do: {:continue, %{path | kept: true, from: []}},
      else: {:continue, %{path | from: Enum.reject(path.from, &match?({:x, _}, &1))}}
  end

  defp step({call, _arity, _}, _idx, _path) when call in [:call_only, :call_ext_only], do: :stop
  defp step({call, _, _, _}, _idx, _path) when call in [:call_last, :call_ext_last], do: :stop
  defp step({:apply_last, _, _}, _idx, _path), do: :stop
  defp step({:func_info, _, _, _}, _idx, _path), do: :stop

  defp step(:return, _idx, path) do
    if not path.replied and not path.kept and unreplied_return?(path),
      do: {:unreplied, path},
      else: {:continue, path}
  end

  defp step(_instr, _idx, path), do: {:continue, path}

  # A write to a register drops it from the `from` set; a write to x0 also
  # forgets what x0 held, until a bare state value is put there.
  defp forget(path, dst) do
    path = %{
      path
      | from: List.delete(path.from, slot(dst)),
        event: List.delete(path.event, slot(dst))
    }

    if slot(dst) == @x0, do: %{path | x0: nil}, else: path
  end

  defp unreplied_return?(path), do: path.x0 == :bare

  # ── Edges ────────────────────────────────────────────────────────────

  # The call tag test is passed; any other test on the event type belongs
  # to another clause and is not followed on its success edge.
  defp follow?(instr, :branch_pass), do: not x0_test?(instr) or call_head?(instr)
  defp follow?(instr, :branch_fail), do: not call_head?(instr)

  defp follow?({op, src, _, _}, {:select_arm, _}) when op in [:select_val, :select_tuple_arity],
    do: slot(src) != @x0

  defp follow?(_instr, _kind), do: true

  defp call_head?({:test, :is_tagged_tuple, _f, [src, 2, {:atom, :call}]}), do: slot(src) == @x0
  defp call_head?(_), do: false

  defp x0_test?({:test, _op, _f, args}), do: @x0 in Enum.map(args, &slot/1)
  defp x0_test?({:test, _op, _f, src, _fields}), do: slot(src) == @x0
  defp x0_test?(_), do: false

  # ── Registers and literals ──────────────────────────────────────────

  defp uses_from?(terms, path), do: Enum.any?(terms, &(slot(&1) in path.from))

  defp literal_atom({:atom, a}), do: a
  defp literal_atom(_), do: nil
end
