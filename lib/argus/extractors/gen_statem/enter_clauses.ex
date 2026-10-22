defmodule Argus.Extractors.GenStatem.EnterClauses do
  @moduledoc """
  Whether a state function's enter call always stops the machine.

  With `state_enter` in its callback mode, gen_statem calls a state's
  function as `state(:enter, old_state, data)` each time the machine
  enters the state, the initial state included, before it hands the
  state any other event. An enter call that returns `{:stop, ...}` or
  `{:stop_and_reply, ...}`, or raises, ends the machine there; when every
  enter call does, the state's other clauses never run.

  ## Reading the bytecode

  The walk starts at the function's entry with `:enter` in `{x, 0}` and
  follows, at a test on `{x, 0}` while it still holds the event, only the
  edge that test takes for `:enter`: the pass edge of `is_eq_exact` with
  `:enter`, the fail edge of a test for a tuple or another atom, the
  `:enter` arm of a `select_val` (its default when it has none). A test
  of the data's shape (`{x, 2}` while it still holds the data: a record's
  tag, a map, the keys a map pattern names, a struct's name) is taken as passed:
  the machine's data has the shape its own clauses take, as
  `Argus.Extractors.GenStatem.EventClauses` takes a clause's demands on
  the data as met. Every other edge is followed: a failed pattern on a
  value of the data falls to a later clause, which may keep the state.

  Every path must end in a return of a stop tuple built into `{x, 0}`
  (`{:stop, reason, data}` built by `put_tuple2`, or a literal one), or
  in a raise. A tail call to anything that may return answers for the
  state, and so does a return of any other value: either is a path that
  may not stop.
  """

  alias Argus.Cfg.{Block, Function}
  alias Argus.Instr
  import Argus.Instr, only: [slot: 1]

  @x0 {:x, 0}
  @data {:x, 2}
  @stops [:stop, :stop_and_reply]
  @shape_tests [:is_tagged_tuple, :is_tuple, :test_arity, :is_map, :has_map_fields]
  @not_atom_tests [
    :is_tuple,
    :is_tagged_tuple,
    :test_arity,
    :is_list,
    :is_nonempty_list,
    :is_nil,
    :is_map,
    :is_binary,
    :is_bitstr,
    :is_integer,
    :is_float,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_function,
    :is_function2
  ]

  @doc "Whether every enter call into the state `fun` handles stops the machine."
  @spec always_stop?(Function.t() | nil, [tuple()]) :: boolean()
  def always_stop?(nil, _instrs), do: false

  def always_stop?(%Function{} = fun, instrs) do
    tuple = List.to_tuple(instrs)

    case walk(fun.entry, %{event: true, data: true, struct: [], x0: nil}, fun, tuple, %{}, :none) do
      {:ok, _seen, :stopped} -> true
      _ -> false
    end
  end

  # Depth-first over {block, path}; `stopped` says whether some path
  # reached a stop return yet. `:escapes` ends the walk.
  defp walk(block_id, path, fun, instrs, seen, stopped) do
    key = {block_id, path}

    if Map.has_key?(seen, key) do
      {:ok, seen, stopped}
    else
      seen = Map.put(seen, key, true)
      %Block{range: {first, last}} = block = Map.fetch!(fun.blocks, block_id)

      first..last
      |> Enum.reduce_while({:next, path}, fn idx, {:next, p} ->
        case step(elem(instrs, idx), p) do
          {:continue, p} -> {:cont, {:next, p}}
          ending -> {:halt, ending}
        end
      end)
      |> case do
        :escapes ->
          :escapes

        :stopped ->
          {:ok, seen, :stopped}

        :raised ->
          {:ok, seen, stopped}

        {:next, path} ->
          successors(block, elem(instrs, last), path, fun, instrs, {:ok, seen, stopped})
      end
    end
  end

  defp successors(block, last_instr, path, fun, instrs, state) do
    block.succs
    |> Enum.filter(fn {_to, kind} -> follow?(last_instr, kind, path) end)
    |> Enum.reduce_while(state, fn {to, _kind}, {:ok, seen, stopped} ->
      case walk(to, path, fun, instrs, seen, stopped) do
        :escapes -> {:halt, :escapes}
        ok -> {:cont, ok}
      end
    end)
  end

  # ── One instruction along a path ────────────────────────────────────

  defp step(:return, %{x0: :stop}), do: :stopped
  defp step(:return, _path), do: :escapes

  defp step({:func_info, _, _, _}, _path), do: :raised
  defp step({op, _}, _path) when op in [:badmatch, :case_end, :try_case_end], do: :raised
  defp step(:if_end, _path), do: :raised

  defp step({:put_tuple2, dst, {:list, [{:atom, head} | _]}}, path) when head in @stops,
    do: {:continue, write(path, dst, :stop)}

  defp step({:move, {:literal, value}, dst}, path)
       when is_tuple(value) and tuple_size(value) > 1 and elem(value, 0) in @stops,
       do: {:continue, write(path, dst, :stop)}

  defp step(instr, path) do
    cond do
      Instr.raising_tail_call?(instr) -> :raised
      Instr.tail_call_op?(elem_op(instr)) -> :escapes
      true -> {:continue, clobber(path, instr)}
    end
  end

  defp clobber(path, instr) do
    path = %{path | struct: Enum.reject(path.struct, &Instr.clobbers?(instr, &1))}
    path = struct_name(path, instr)
    path = if Instr.clobbers?(instr, @data), do: %{path | data: false}, else: path
    if Instr.clobbers?(instr, @x0), do: %{path | event: false, x0: nil}, else: path
  end

  # The register a struct pattern on the data reads its name into.
  defp struct_name(%{data: true} = path, {:get_map_elements, _f, src, {:list, pairs}}) do
    if slot(src) == @data do
      names = for [{:atom, :__struct__}, reg] <- Enum.chunk_every(pairs, 2), do: slot(reg)
      %{path | struct: names ++ path.struct}
    else
      path
    end
  end

  defp struct_name(path, _instr), do: path

  defp write(path, dst, value) do
    case slot(dst) do
      @x0 -> %{path | event: false, x0: value}
      @data -> %{path | data: false}
      _ -> path
    end
  end

  defp elem_op(instr) when is_tuple(instr) and tuple_size(instr) > 0, do: elem(instr, 0)
  defp elem_op(instr) when is_atom(instr), do: instr
  defp elem_op(_instr), do: nil

  # ── Edges ────────────────────────────────────────────────────────────

  defp follow?(instr, kind, path) do
    cond do
      path.data and data_shape?(instr) -> kind == :branch_pass
      struct_test?(instr, path.struct) -> kind == :branch_pass
      path.event -> enter_follows?(instr, kind)
      true -> true
    end
  end

  defp enter_follows?(instr, kind) do
    case enter_takes(instr) do
      :unknown -> true
      taken -> taken == kind
    end
  end

  defp data_shape?({:test, op, _f, [src | _]}) when op in @shape_tests, do: slot(src) == @data
  defp data_shape?({:test, op, _f, src, _fields}) when op in @shape_tests, do: slot(src) == @data
  defp data_shape?({:get_map_elements, _f, src, _pairs}), do: slot(src) == @data
  defp data_shape?(_instr), do: false

  defp struct_test?({:test, :is_eq_exact, _f, [a, {:atom, _}]}, struct), do: slot(a) in struct
  defp struct_test?(_instr, _struct), do: false

  # The edge a test on `{x, 0}` takes when it holds `:enter`, or `:unknown`.
  defp enter_takes({:test, op, _f, [a, b]}) when op in [:is_eq_exact, :is_eq] do
    case compared(a, b) do
      {:ok, atom} -> if atom == :enter, do: :branch_pass, else: :branch_fail
      :unknown -> :unknown
    end
  end

  defp enter_takes({:test, op, _f, [a, b]}) when op in [:is_ne_exact, :is_ne] do
    case compared(a, b) do
      {:ok, atom} -> if atom == :enter, do: :branch_fail, else: :branch_pass
      :unknown -> :unknown
    end
  end

  defp enter_takes({:test, :is_atom, _f, [src]}),
    do: if(slot(src) == @x0, do: :branch_pass, else: :unknown)

  defp enter_takes({:test, op, _f, [src | _]}) when op in @not_atom_tests,
    do: if(slot(src) == @x0, do: :branch_fail, else: :unknown)

  defp enter_takes({:select_val, src, _f, {:list, entries}}) do
    cond do
      slot(src) != @x0 -> :unknown
      {:atom, :enter} in entries -> {:select_arm, inspect(:enter)}
      true -> :select_fail
    end
  end

  defp enter_takes({:select_tuple_arity, src, _f, _arms}),
    do: if(slot(src) == @x0, do: :select_fail, else: :unknown)

  defp enter_takes(_instr), do: :unknown

  defp compared(a, b) do
    case {slot(a), slot(b)} do
      {@x0, _} -> atom_of(b)
      {_, @x0} -> atom_of(a)
      _ -> :unknown
    end
  end

  defp atom_of({:atom, atom}), do: {:ok, atom}
  defp atom_of({:literal, value}), do: {:ok, value}
  defp atom_of(_operand), do: :unknown
end
