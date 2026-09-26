defmodule Argus.Extractors.Handles do
  @moduledoc """
  A file, a socket or a port a function opens and then loses on some
  path, without closing it or handing it on.

  The process that opens one owns it until it closes it or exits: an
  open file (a raw descriptor, or the io server `:file.open/2` links to
  its caller), a socket (`:gen_tcp`, `:ssl`, `:gen_udp`, `:socket`) or a
  port. A long-lived process that opens one per request, per reconnect
  or per retry and drops it on an error path holds one more descriptor
  each time, until the node runs out (thousand_island's `sendfile/4`
  opened a raw fd per call and never closed it; mint's HTTP/1 transport
  errors left the socket open).

  ## Reading the bytecode

  From each opening call, a walk of every path forward that carries the
  registers holding what the call answered (`{:ok, handle}`, or the
  handle itself) and, once a path takes the handle out of the tuple, the
  registers holding the handle (`Argus.Instr.carry/2`, and what an
  instruction builds from them). On a path the handle is:

  - handed on, and the path is done: returned, sent as data, built into
    a term (a state, a reply), or given to any call other than the few
    below — `:file.close/1`, `:gen_tcp.controlling_process/2`, a helper
    of the program, all alike;
  - used, and the path goes on: read, written, sent on, its options
    set, tested — the operations that leave it open (`@leave_open`),
    with the handle as their first argument;
  - dropped: no register holds it any more (a call the compiler did not
    keep it across, the frame deallocated), the function returns or
    tail-calls without it, or tail-calls one of those operations, whose
    result it returns and the handle not.

  A path on which the tuple was never taken apart — the `{:error, _}`
  arm — owns no handle. A path that raises drops nothing here: the
  process exits or a handler up the stack decides. The first drop in
  instruction order names the path (`handle_dropped`).

  ## Emitted facts

  - `handle_dropped(id, func, api, drop)` — the handle the call at `id`
    (`api`) opens is dropped at `drop`, on some path from it.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Block
  alias Argus.Cfg.Function, as: Graph
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  # Calls that open a handle: `:ok` when they answer `{:ok, handle}`,
  # `:bare` when they answer the handle itself (or raise).
  @opens %{
    {:file, :open, 2} => :ok,
    {File, :open, 1} => :ok,
    {File, :open, 2} => :ok,
    {File, :open!, 1} => :bare,
    {File, :open!, 2} => :bare,
    {:gen_tcp, :connect, 3} => :ok,
    {:gen_tcp, :connect, 4} => :ok,
    {:gen_tcp, :listen, 2} => :ok,
    {:gen_tcp, :accept, 1} => :ok,
    {:gen_tcp, :accept, 2} => :ok,
    {:ssl, :connect, 2} => :ok,
    {:ssl, :connect, 3} => :ok,
    {:ssl, :connect, 4} => :ok,
    {:ssl, :listen, 2} => :ok,
    {:gen_udp, :open, 1} => :ok,
    {:gen_udp, :open, 2} => :ok,
    {:socket, :open, 2} => :ok,
    {:socket, :open, 3} => :ok,
    {:socket, :open, 4} => :ok,
    {:socket, :accept, 1} => :ok,
    {:socket, :accept, 2} => :ok,
    {Port, :open, 2} => :bare,
    {:erlang, :open_port, 2} => :bare
  }

  # Operations that leave the handle (their first argument) open and
  # owned by the caller.
  @leave_open MapSet.new([
                {:file, :read, 2},
                {:file, :pread, 2},
                {:file, :pread, 3},
                {:file, :write, 2},
                {:file, :pwrite, 2},
                {:file, :pwrite, 3},
                {:file, :position, 2},
                {:file, :sendfile, 5},
                {:file, :read_line, 1},
                {:file, :sync, 1},
                {:file, :datasync, 1},
                {:file, :truncate, 1},
                {:file, :advise, 4},
                {:file, :allocate, 3},
                {IO, :binread, 2},
                {IO, :binwrite, 2},
                {IO, :read, 2},
                {IO, :write, 2},
                {IO, :puts, 2},
                {IO, :gets, 2},
                {:io, :format, 3},
                {:io, :fwrite, 3},
                {:io, :put_chars, 2},
                {:io, :get_line, 2},
                {:gen_tcp, :send, 2},
                {:gen_tcp, :recv, 2},
                {:gen_tcp, :recv, 3},
                {:gen_udp, :send, 2},
                {:gen_udp, :send, 3},
                {:gen_udp, :send, 4},
                {:gen_udp, :send, 5},
                {:gen_udp, :recv, 2},
                {:gen_udp, :recv, 3},
                {:inet, :setopts, 2},
                {:inet, :getopts, 2},
                {:inet, :peername, 1},
                {:inet, :sockname, 1},
                {:inet, :port, 1},
                {:ssl, :send, 2},
                {:ssl, :recv, 2},
                {:ssl, :recv, 3},
                {:ssl, :setopts, 2},
                {:ssl, :getopts, 2},
                {:ssl, :peername, 1},
                {:ssl, :sockname, 1},
                {:ssl, :peercert, 1},
                {:ssl, :connection_information, 1},
                {:ssl, :connection_information, 2},
                {:socket, :send, 2},
                {:socket, :send, 3},
                {:socket, :send, 4},
                {:socket, :recv, 1},
                {:socket, :recv, 2},
                {:socket, :recv, 3},
                {:socket, :recv, 4},
                {:socket, :setopt, 3},
                {:socket, :getopt, 2},
                {:socket, :sockname, 1},
                {:socket, :peername, 1},
                {Port, :command, 2},
                {Port, :command, 3},
                {Port, :info, 1},
                {Port, :info, 2},
                {:erlang, :port_command, 2},
                {:erlang, :port_command, 3},
                {:erlang, :port_info, 1},
                {:erlang, :port_info, 2},
                {:erlang, :port_control, 3},
                # Looked at, not taken: an inspect for a log line.
                {Kernel, :inspect, 1},
                {Kernel, :inspect, 2},
                {IO, :inspect, 1},
                {IO, :inspect, 2}
              ])

  # Every path's steps are bounded by the function's instructions and the
  # register sets they carry; this guards a bug, not a program.
  @max_states 20_000

  @impl true
  def relations, do: [:handle_dropped]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.filter(&(&1.remote? and Map.has_key?(@opens, &1.mfa)))
    |> Enum.group_by(& &1.func_id)
    |> Enum.reduce(%{}, fn {func_id, sites}, facts ->
      {name, arity} = Normalize.func_id_name_arity(func_id)

      case Helpers.cfg(module_data, name, arity) do
        nil ->
          facts

        graph ->
          code = sites |> hd() |> Map.fetch!(:instrs) |> List.to_tuple()
          Enum.reduce(sites, facts, &opened(&2, &1, graph, code))
      end
    end)
  end

  defp opened(facts, %{func_id: func_id, idx: idx, mfa: {mod, fun, arity} = mfa}, graph, code) do
    # A tail call hands what it answers to the caller: nothing left here.
    if Instr.tail_call?(elem(code, idx)) do
      facts
    else
      start =
        case Map.fetch!(@opens, mfa) do
          :ok -> %{tuple: [{:x, 0}], handle: [], tags: [], owned: false, gone: nil}
          :bare -> %{tuple: [], handle: [{:x, 0}], tags: [], owned: true, gone: nil}
        end

      case drop(graph, code, [{idx + 1, start}], %{}, nil) do
        nil ->
          facts

        at ->
          add_fact(facts, :handle_dropped, [
            InstrId.mint(func_id, idx),
            func_id,
            Exception.format_mfa(mod, fun, arity),
            InstrId.mint(func_id, at)
          ])
      end
    end
  end

  # The first instruction (in order) at which some path that goes on to
  # return drops the handle, or nil. A path whose registers no longer
  # hold the handle is walked on (`gone`, where it went) until it
  # returns — a drop — or raises, which drops nothing here. `seen` holds
  # the states already walked; each is walked once.
  defp drop(_graph, _code, [], _seen, first), do: first

  defp drop(graph, code, [{idx, regs} = state | rest], seen, first) do
    cond do
      map_size(seen) > @max_states ->
        first

      idx >= tuple_size(code) or Map.has_key?(seen, state) ->
        drop(graph, code, rest, seen, first)

      true ->
        seen = Map.put(seen, state, true)
        instr = elem(code, idx)

        case step(instr, idx, regs) do
          :done ->
            drop(graph, code, rest, seen, first)

          {:dropped, at} ->
            drop(graph, code, rest, seen, earliest(first, at))

          {:next, regs} ->
            next =
              for at <- successors(graph, code, idx),
                  do: {at, gone(established(graph, instr, idx, at, regs), idx)}

            drop(graph, code, next ++ rest, seen, first)
        end
    end
  end

  # Past the instruction at which no register holds the handle any more,
  # the path has lost it there.
  defp gone(%{owned: true, gone: nil, tuple: [], handle: []}, idx),
    do: %{tuple: [], handle: [], tags: [], owned: true, gone: idx}

  defp gone(regs, _idx), do: regs

  # A path owns the handle once it has taken the `{:ok, _}` arm — the
  # pass edge of `is_tagged_tuple(answer, 2, :ok)`, or of a test of the
  # answer's tag (element 0) against `:ok`, or a select's `:ok` arm on
  # it — even where the compiler takes the handle out of the tuple only
  # on the paths that use it.
  defp established(_graph, _instr, _idx, _at, %{owned: true} = regs), do: regs

  defp established(graph, instr, idx, at, regs) do
    if ok_edge?(graph, instr, idx, at, regs), do: %{regs | owned: true}, else: regs
  end

  defp ok_edge?(_graph, {:test, :is_tagged_tuple, _fail, [t, 2, {:atom, :ok}]}, idx, at, regs),
    do: at == idx + 1 and Instr.register(t) in regs.tuple

  defp ok_edge?(_graph, {:test, :is_eq_exact, _fail, [a, b]}, idx, at, regs) do
    at == idx + 1 and
      ((Instr.register(a) in regs.tags and b == {:atom, :ok}) or
         (Instr.register(b) in regs.tags and a == {:atom, :ok}))
  end

  defp ok_edge?(graph, {:select_val, r, _fail, {:list, pairs}}, _idx, at, regs) do
    with true <- Instr.register(r) in regs.tags,
         {:f, label} <- ok_arm(pairs),
         block when block != nil <- Map.get(graph.labels, label),
         %Block{range: {first, _}} <- Map.get(graph.blocks, block) do
      first == at
    else
      _ -> false
    end
  end

  defp ok_edge?(_graph, _instr, _idx, _at, _regs), do: false

  defp ok_arm([{:atom, :ok}, label | _rest]), do: label
  defp ok_arm([_value, _label | rest]), do: ok_arm(rest)
  defp ok_arm(_pairs), do: nil

  defp earliest(nil, idx), do: idx
  defp earliest(first, idx), do: min(first, idx)

  # What `instr` does on a path: `:done` (the handle handed on, or none
  # on this path), `{:dropped, at}` (the path returns without it, lost
  # at `at`), or `{:next, regs}`.
  defp step(instr, _idx, %{gone: at} = regs) when at != nil do
    cond do
      raises?(instr) -> :done
      Instr.exits?(instr) -> {:dropped, at}
      true -> {:next, regs}
    end
  end

  defp step(instr, idx, regs) do
    reads = Instr.uses(instr)
    tuple_read = Enum.filter(reads, &(&1 in regs.tuple))
    handle_read = Enum.filter(reads, &(&1 in regs.handle))

    cond do
      not Instr.known?(instr) -> :done
      handle_read == [] and tuple_read != [] -> tuple_use(instr, tuple_read, regs)
      handle_read != [] -> handle_use(instr, idx, handle_read, regs)
      copy?(instr) -> {:next, carry(instr, regs)}
      raises?(instr) -> :done
      Instr.exits?(instr) -> if regs.owned, do: {:dropped, idx}, else: :done
      true -> {:next, carry(instr, regs)}
    end
  end

  # What an instruction reading the answer, and not the handle, does:
  # takes the handle out (the second element: the handle on the `{:ok,
  # _}` arm, the reason on the `{:error, _}` one; the path owns a handle
  # only once it takes the `:ok` arm, `established/5`), reads the tag a
  # `case` picks its arm by, copies or tests it, looks at it (an inspect
  # for a log line), or hands the whole answer on.
  defp tuple_use({:get_tuple_element, _src, 1, dst} = instr, _read, regs) do
    carried = carry(instr, regs)
    {:next, %{carried | handle: Enum.sort(Enum.uniq([Instr.register(dst) | carried.handle]))}}
  end

  defp tuple_use({:get_tuple_element, _src, 0, dst} = instr, _read, regs) do
    carried = carry(instr, regs)
    {:next, %{carried | tags: Enum.sort(Enum.uniq([Instr.register(dst) | carried.tags]))}}
  end

  defp tuple_use(instr, read, regs) do
    if match?({:get_tuple_element, _, _, _}, instr) or copy?(instr) or test?(instr) or
         leaves_open?(instr, read),
       do: {:next, carry(instr, regs)},
       else: :done
  end

  defp handle_use(instr, idx, read, regs) do
    cond do
      test?(instr) ->
        {:next, carry(instr, regs)}

      # The operation's result is returned, and the handle not.
      leaves_open?(instr, read) and Instr.tail_call?(instr) ->
        {:dropped, idx}

      leaves_open?(instr, read) ->
        {:next, carry(instr, regs)}

      # A send to the handle (a port's command) addresses it; a send of
      # it hands it on.
      send?(instr) and read == [{:x, 0}] ->
        {:next, carry(instr, regs)}

      true ->
        :done
    end
  end

  defp copy?(instr), do: is_tuple(instr) and elem(instr, 0) in [:move, :swap, :trim]

  defp carry(instr, regs) do
    %{
      regs
      | tuple: instr |> Instr.carry(regs.tuple) |> Enum.sort(),
        handle: instr |> Instr.carry(regs.handle) |> Enum.sort(),
        tags: instr |> Instr.carry(regs.tags) |> Enum.sort()
    }
  end

  # A call that never returns: the path raises.
  @raising [
    {:erlang, :error, 1},
    {:erlang, :error, 2},
    {:erlang, :error, 3},
    {:erlang, :exit, 1},
    {:erlang, :throw, 1},
    {:erlang, :raise, 3}
  ]

  defp raises?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, m, f, a} -> {m, f, a} in @raising
      :none -> false
    end
  end

  defp test?(instr) when is_tuple(instr),
    do: elem(instr, 0) in [:test, :select_val, :select_tuple_arity]

  defp test?(_instr), do: false

  defp send?(:send), do: true
  defp send?({:call_ext, 2, {:extfunc, :erlang, :send, 2}}), do: true
  defp send?(_instr), do: false

  defp leaves_open?(instr, read) do
    case Helpers.match_remote_call(instr) do
      {:ok, m, f, a} -> MapSet.member?(@leave_open, {m, f, a}) and read == [{:x, 0}]
      :none -> false
    end
  end

  # Within a block the next instruction; at its last, the first of each
  # block it may go to.
  defp successors(graph, code, idx) do
    case Graph.block_at(graph, idx) do
      %Block{range: {_first, last}} = block when last == idx ->
        for {to, _kind} <- block.succs,
            %Block{range: {first, _}} = Map.fetch!(graph.blocks, to),
            do: first

      _ ->
        if idx + 1 < tuple_size(code), do: [idx + 1], else: []
    end
  end
end
