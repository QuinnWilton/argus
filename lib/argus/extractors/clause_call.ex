defmodule Argus.Extractors.ClauseCall do
  @moduledoc """
  The clause each call runs in, for a function that chooses its clause
  by its first argument.

  `handle_call({:answer, n}, _, s)` and `handle_call({:echo, n}, _, s)`
  compile into one function, and so do `route(:local, n)` and
  `route(:remote, n)`: a call graph by function merges the clauses, so a
  request that enters one clause is charged with the calls of every
  other. This names, for each call, the first-argument tag the paths to
  it established (`Argus.Extractor.Dispatch.argument_tags/2`), so a rule
  can follow the clause a request or a literal argument enters.

  ## Emitted facts

  - `clause_call(id, func, tag)` — the call at `id` runs only while
    `func`'s first argument is `tag` (an atom, or a tuple headed by it,
    inspected); one row per tag some path to it establishes. A call some
    path reaches without establishing one has no row: it runs whatever
    the argument is. Erlang's `!` (the `send` instruction) is asked as a
    call is.
  - `info_clause_always(id, func, tag)` — in a `handle_info/2`, the call
    (or send) at `id` runs on every path the clause for the atom `tag`
    takes to a return that goes on: every `return` or tail call the
    message reaches (`Dispatch.reached_with/4`) is reached only through
    `id`, leaving out a return of `{:stop, ...}`, which ends the loop. A
    clause that re-arms its own timer this way runs a periodic loop; one
    that re-arms on one branch (a failed connect) retries until it is
    done.

  What a `terminate/2` runs for the reason a supervisor's stop passes is
  `Argus.Extractors.ShutdownReason`'s.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:clause_call, :info_clause_always]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    ending = {Map.get(module_data, :module), ending_functions(module_data)}

    module_data
    |> CallSites.for_module()
    |> Enum.concat(send_sites(module_data))
    |> Enum.group_by(& &1.func_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {func_id, [%{instrs: instrs} | _] = sites}, acc ->
      if dispatches_on_first?(instrs),
        do: emit(acc, func_id, instrs, Enum.sort_by(sites, & &1.idx), ending),
        else: acc
    end)
  end

  # The functions of the module every completion of which stops the
  # process or hands it to handle_continue/2: the clauses of a `with`'s
  # `else` the compiler lifts into a local fun
  # (`{:error, r} -> {:noreply, s, {:continue, {:disconnected, r}}}`),
  # and what tail-calls only such functions. A tail call to one is no
  # path by which the caller goes on. A plain map, not a MapSet: dialyzer
  # loses the MapSet's opacity through the recursion.
  defp ending_functions(%{module: mod, functions: functions}) do
    bodies =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, instrs}
      end)

    grow_ending(mod, bodies, %{})
  end

  defp ending_functions(_module_data), do: %{}

  defp grow_ending(mod, bodies, ending) do
    grown =
      for {key, instrs} <- bodies,
          not Map.has_key?(ending, key),
          going_on(instrs, mod, ending) == [],
          Enum.any?(instrs, &(&1 == :return or Instr.tail_call?(&1))),
          reduce: ending do
        acc -> Map.put(acc, key, true)
      end

    if map_size(grown) == map_size(ending),
      do: ending,
      else: grow_ending(mod, bodies, grown)
  end

  # Erlang's `Pid ! Msg` is the `send` instruction, not a call to
  # erlang:send/2 as Elixir's send/2 compiles: the clause a self-send
  # runs in (a loop's own tick re-sent) is asked as a call's is.
  defp send_sites(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        {:send, idx} <- Enum.with_index(instrs),
        do: %{func_id: Normalize.func_id(mod, name, arity), instrs: instrs, idx: idx}
  end

  defp send_sites(_module_data), do: []

  defp emit(facts, func_id, instrs, sites, ending) do
    tags = Dispatch.argument_tags(instrs, {:x, 0})

    facts =
      for site <- sites,
          set = Map.get(tags, site.idx, MapSet.new([:any])),
          not MapSet.member?(set, :any),
          tag <- Enum.sort(set),
          reduce: facts do
        acc -> add_fact(acc, :clause_call, [InstrId.mint(func_id, site.idx), func_id, tag])
      end

    if String.ends_with?(func_id, ":handle_info/2"),
      do: emit_always(facts, func_id, instrs, sites, tags, ending),
      else: facts
  end

  # For each atom tag a site's clause names: the returns and tail calls
  # the message reaches that let the process go on, and whether each is
  # reached only through the site.
  defp emit_always(facts, func_id, instrs, sites, tags, {mod, ending}) do
    ends = going_on(instrs, mod, ending)
    handed = handed_on(instrs, mod, ending)

    tagged =
      for site <- sites,
          set = Map.get(tags, site.idx, MapSet.new([:any])),
          not MapSet.member?(set, :any),
          tag <- Enum.sort(set),
          atom = tag_atom(tag),
          atom != nil,
          do: {site, tag, atom}

    reached =
      tagged
      |> Enum.map(fn {_site, _tag, atom} -> atom end)
      |> Enum.uniq()
      |> Map.new(fn atom -> {atom, Dispatch.reached_with(instrs, {:x, 0}, atom)} end)

    # The sites of one tag that do the same thing — call one function, or
    # arm or send one message — stand together: three clauses for a
    # message that each call `schedule_check(ms)` re-arm on every path
    # between them, though no one site is on all of them.
    groups = Enum.group_by(tagged, fn {site, tag, _atom} -> {tag, act(instrs, site)} end)

    for {{tag, _act}, [{_site, _tag, atom} | _] = group} <- Enum.sort(groups),
        ends_here = Enum.filter(ends, &MapSet.member?(reached[atom], &1)),
        # A path the clause hands to handle_continue/2 goes on too, and
        # asks nothing of the arm (the continue decides what comes next);
        # a clause that arms and then only continues is a loop all the
        # same (review 2, item 21: 567e3256 read it as no path on).
        ends_here != [] or Enum.any?(handed, &MapSet.member?(reached[atom], &1)),
        without =
          Dispatch.reached_with(
            instrs,
            {:x, 0},
            atom,
            Enum.map(group, fn {site, _, _} -> site.idx end)
          ),
        not Enum.any?(ends_here, &MapSet.member?(without, &1)),
        {site, _tag, _atom} <- group,
        reduce: facts do
      acc -> add_fact(acc, :info_clause_always, [InstrId.mint(func_id, site.idx), func_id, tag])
    end
  end

  # What a site does, for telling sites of one clause apart: the message
  # a timer or a send carries, else the function it calls.
  @message_register %{
    {:erlang, :send_after, 3} => 2,
    {:erlang, :send_after, 4} => 2,
    {:erlang, :start_timer, 3} => 2,
    {:erlang, :start_timer, 4} => 2,
    {:timer, :send_after, 2} => 1,
    {:timer, :send_after, 3} => 2,
    {:timer, :send_interval, 2} => 1,
    {:timer, :send_interval, 3} => 2,
    {:erlang, :send, 2} => 1,
    {:erlang, :send, 3} => 1
  }

  defp act(instrs, %{idx: idx} = site) do
    mfa = Map.get(site, :mfa, :send)

    case Map.get(@message_register, mfa, if(mfa == :send, do: 1)) do
      nil -> mfa
      reg -> {mfa, Resolve.resolve_register(instrs, idx, {:x, reg})}
    end
  end

  # The returns and tail calls that leave the process running: every one
  # but a return of `{:stop, ...}` and a tail call that raises (the
  # compiler's `:erlang.error({:badmap, _})`, a `raise`), which the graph
  # counts as a tail call like any other.
  defp going_on(instrs, mod, ending) do
    for {instr, idx} <- Enum.with_index(instrs),
        instr == :return or (Instr.tail_call?(instr) and not raises?(instr)),
        not stops?(instrs, idx, instr),
        not ends_in?(instr, mod, ending),
        do: idx
  end

  # The returns that hand the process to handle_continue/2, and the tail
  # calls into a function of the module every completion of which stops
  # or continues: paths that go on without asking the loop's arm.
  defp handed_on(instrs, mod, ending) do
    for {instr, idx} <- Enum.with_index(instrs),
        (instr == :return and continue_return?(instrs, idx)) or
          (Instr.tail_call?(instr) and not raises?(instr) and ends_in?(instr, mod, ending)),
        do: idx
  end

  defp continue_return?(instrs, idx) do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, value} when is_tuple(value) and tuple_size(value) > 0 -> continues?(value)
      _ -> false
    end
  end

  defp ends_in?(instr, mod, ending) do
    case Helpers.match_local_call(instr) do
      {:ok, ^mod, f, a} -> Map.has_key?(ending, {f, a})
      _ -> false
    end
  end

  @raising ~w(error exit throw raise nif_error)a

  defp raises?({:call_ext_last, _arity, {:extfunc, :erlang, f, _}, _dealloc}),
    do: f in @raising

  defp raises?({:call_ext_only, _arity, {:extfunc, :erlang, f, _}}), do: f in @raising
  defp raises?(_instr), do: false

  # A return that stops the process, or hands it to handle_continue/2
  # (`{:noreply, state, {:continue, {:disconnected, reason}}}`): the loop
  # ends there, or the continue decides what comes next (xandra's refresh
  # loop reconnects after a failed refresh, and re-arms from there).
  defp stops?(instrs, idx, :return) do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, value} when is_tuple(value) and tuple_size(value) > 0 ->
        elem(value, 0) == :stop or continues?(value)

      _ ->
        false
    end
  end

  defp stops?(_instrs, _idx, _tail_call), do: false

  defp continues?(value) do
    case elem(value, tuple_size(value) - 1) do
      {:continue, _} -> true
      _ -> false
    end
  end

  # A tag as argument_tags spells it (`inspect/1` of the atom), back to
  # the atom; a tuple's tag is spelled the same, and the atom compared is
  # its first element, which reached_with does not follow.
  defp tag_atom(":" <> _ = tag) do
    case Code.string_to_quoted(tag) do
      {:ok, atom} when is_atom(atom) -> atom
      _ -> nil
    end
  end

  defp tag_atom(_tag), do: nil

  # The walk is paid only by a function that compares its first argument,
  # or the first element of it, with an atom somewhere: the rest have no
  # tag to establish.
  defp dispatches_on_first?(instrs), do: Enum.any?(instrs, &tests_first?/1)

  defp tests_first?({:test, :is_tagged_tuple, _fail, [src | _]}), do: first?(src)

  defp tests_first?({:test, op, _fail, [a, b]}) when op in [:is_eq_exact, :is_ne_exact],
    do: first?(a) or first?(b)

  defp tests_first?({:select_val, src, _fail, _arms}), do: first?(src)
  defp tests_first?({:get_tuple_element, src, 0, _dst}), do: first?(src)
  defp tests_first?(_instr), do: false

  defp first?(operand), do: Instr.register(operand) == {:x, 0}
end
