defmodule Argus.Extractors.ErrorHandling.Boundary do
  @moduledoc """
  Whether a `try` (or Erlang `catch`) protects nothing but operations
  whose failure is another process's, a port's or a name's state.

  A catch-all around `send(pid, msg)`, `GenServer.call(server, req)`,
  `:supervisor.which_children(sup)` or `:ets.new(name, [:named_table |
  _])` takes a dead peer, a timeout, a node gone, a name already taken:
  what the program set out to tolerate when it wrapped the operation.
  None of it is a bug in the code the try protects, and the peer that
  crashed logged its own crash. `failure.unhandled_failure`'s "rescue"
  kind is about the other kind of try — one around the program's own
  logic, where a catch-all turns a bug into silence.

  So a region qualifies when every instruction in it is either one of
  those operations or cannot raise at all: moves, term construction,
  allocation, line markers, jumps and branches, a guard BIF with a fail
  label, a comparison or a type test. Anything else — a call to any
  other function, a BIF that raises, arithmetic, a `badmatch` or a
  `case_end` — may be the program's own failure, and the region does
  not. This list says only what `Argus.Instr` does not, whether an
  instruction can raise, and a kind it does not list is taken to.

  A region that builds and emits a log line and does nothing else
  qualifies too (`log_region?/3`): what a catch-all there hides is a
  failed log handler or a malformed log argument, and what is lost is
  the line.
  """

  alias Argus.Extractor.Helpers

  # Calls whose failure is the state of something else: a process, a
  # node, a port, a registered name. The first four are :erlang BIFs a
  # call_ext names (a send written `send/2` compiles to the `send`
  # instruction, below).
  @boundary_calls MapSet.new([
                    {:erlang, :send, 2},
                    {:erlang, :send, 3},
                    {:erlang, :exit, 2},
                    {:erlang, :port_close, 1},
                    {:erlang, :register, 2},
                    {:erlang, :unregister, 1},
                    {:erlang, :monitor, 2},
                    {:erlang, :demonitor, 1},
                    {:erlang, :demonitor, 2},
                    {:erlang, :link, 1},
                    {:erlang, :unlink, 1},
                    {:erlang, :whereis, 1},
                    {:global, :send, 2},
                    {:ets, :new, 2},
                    {:gen, :call, 3},
                    {:gen, :call, 4},
                    {:gen_server, :call, 2},
                    {:gen_server, :call, 3},
                    {:gen_server, :stop, 1},
                    {:gen_server, :stop, 3},
                    {:gen_statem, :call, 2},
                    {:gen_statem, :call, 3},
                    {:gen_statem, :stop, 1},
                    {:gen_statem, :stop, 3},
                    {:proc_lib, :stop, 1},
                    {:proc_lib, :stop, 3},
                    {GenServer, :call, 2},
                    {GenServer, :call, 3},
                    {GenServer, :stop, 1},
                    {GenServer, :stop, 3},
                    {:supervisor, :which_children, 1},
                    {:supervisor, :count_children, 1},
                    {:supervisor, :start_child, 2},
                    {:supervisor, :terminate_child, 2},
                    {:supervisor, :delete_child, 2},
                    {:supervisor, :restart_child, 2},
                    {Supervisor, :which_children, 1},
                    {Supervisor, :count_children, 1},
                    {Supervisor, :start_child, 2},
                    {Supervisor, :terminate_child, 2},
                    {Supervisor, :delete_child, 2},
                    {Supervisor, :restart_child, 2},
                    {:erpc, :call, 4},
                    {:erpc, :call, 5},
                    {:gen_statem, :cast, 2},
                    {:gen_server, :cast, 2},
                    {GenServer, :cast, 2},
                    {:gen_fsm, :sync_send_event, 2},
                    {:gen_fsm, :sync_send_event, 3},
                    {:gen_fsm, :sync_send_all_state_event, 2},
                    {:gen_fsm, :sync_send_all_state_event, 3},
                    {:gen_fsm, :send_event, 2},
                    {:gen_fsm, :send_all_state_event, 2}
                  ])

  # Instructions that cannot raise: they move, build and allocate, mark
  # lines, and branch rather than fail.
  @inert [
    :move,
    :swap,
    :put_tuple2,
    :put_list,
    :test_heap,
    :allocate,
    :allocate_zero,
    :allocate_heap,
    :allocate_heap_zero,
    :deallocate,
    :init_yregs,
    :kill,
    :trim,
    :line,
    :debug_line,
    :executable_line,
    :label,
    :jump,
    :try_end,
    :catch_end,
    :test,
    :select_val,
    :select_tuple_arity,
    :get_tuple_element,
    :get_list,
    :get_hd,
    :get_tl,
    :make_fun3
  ]

  # BIFs that answer for any argument: comparisons, type tests, self().
  @total_bifs [
    :==,
    :"/=",
    :"=:=",
    :"=/=",
    :<,
    :>,
    :"=<",
    :>=,
    :not,
    :self,
    :node,
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple
  ]

  @doc """
  Whether the region `visited` (instruction indices into `table`, the
  function's instructions as a tuple) holds at least one boundary
  operation and nothing else that can raise, or builds and emits a log
  line and nothing else (`log_region?/2`).
  """
  @spec region?(Enumerable.t(non_neg_integer()), tuple(), %{pos_integer() => pos_integer()}) ::
          boolean()
  def region?(visited, table, line_table \\ %{}) do
    instrs = Enum.map(visited, &elem(table, &1))

    (Enum.any?(instrs, &boundary?/1) and Enum.all?(instrs, &(boundary?(&1) or inert?(&1)))) or
      log_region?(visited, table, line_table)
  end

  # ── A region of calls, and a function that is one boundary op ───────
  #
  # A client API is the same boundary one hop away: hackney's
  # `hackney_conn:stop(Pid) -> gen_statem:stop(Pid)`, vernemq's
  # `vmq_queue:status(Pid)`. Whether the callee is one is known only once
  # every module's functions are, so the extractor says of each function
  # whether it is (`function?/1`), and of each try region made of calls
  # and inert instructions which calls it would have to be
  # (`wrapper_calls/2`); the rule joins the two.

  @doc """
  Whether a function's instructions are boundary operations and
  instructions that cannot raise, with at least one boundary operation:
  a one-hop client API. Returns and tail calls end it.
  """
  @spec function?([tuple() | atom()]) :: boolean()
  def function?(instrs) do
    body = Enum.reject(instrs, &(&1 == :return or match?({:func_info, _, _, _}, &1)))

    Enum.any?(body, &boundary_op?/1) and
      Enum.all?(body, &(boundary_op?(&1) or inert?(&1)))
  end

  # A boundary call as a tail call too: a wrapper's body is often one.
  defp boundary_op?(instr) do
    boundary?(instr) or
      case Helpers.match_remote_call(instr) do
        {:ok, m, f, a} -> MapSet.member?(@boundary_calls, {m, f, a})
        :none -> false
      end
  end

  @doc """
  The calls in the region `visited` that are not boundary operations,
  when every other instruction in it is a boundary operation or cannot
  raise, and every such call names its callee: `{:ok, indices}` (at
  least one), else `:error`.
  """
  @spec wrapper_calls(Enumerable.t(non_neg_integer()), tuple()) ::
          {:ok, [non_neg_integer()]} | :error
  def wrapper_calls(visited, table) do
    Enum.reduce_while(Enum.sort(visited), {:ok, []}, fn idx, {:ok, acc} ->
      instr = elem(table, idx)

      cond do
        boundary?(instr) or inert?(instr) -> {:cont, {:ok, acc}}
        named_call?(instr) -> {:cont, {:ok, [idx | acc]}}
        true -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, [_ | _] = calls} -> {:ok, Enum.reverse(calls)}
      _ -> :error
    end
  end

  defp named_call?(instr) do
    Helpers.match_remote_call(instr) != :none or Helpers.match_local_call(instr) != :none
  end

  # ── A try around a log line ─────────────────────────────────────────
  #
  # ra's logging macro wraps every log line in `try ... catch _:_ -> ok
  # end`, so that a log handler's failure never takes the Raft server
  # down: 178 of ra's catch-alls are that macro. What it protects is the
  # line and the terms its arguments are built from; a bug the catch
  # hides is a malformed log argument, and the line is what is lost.
  #
  # A region qualifies when it is straight-line code (no branch but the
  # try's own), holds at least one log call, and every other instruction
  # that can raise — a call, a raising BIF — produces a value that flows,
  # through moves and the terms built from it, into a log call's
  # arguments, from a source line no earlier than that log call's: the
  # log statement's own arguments, not a statement before it.
  # `do_work(); Logger.info("done")` does not qualify (do_work's result
  # goes nowhere), nor does `r = do_work()` on the line before
  # `Logger.info(inspect(r))`: the try protects do_work too. Without a
  # line table the second test cannot be made, and nothing qualifies.

  # The log call: a logger API, or an apply whose function is `log` on a
  # module the program computes (ra's `(ra_env:logger_mod()):log(...)`,
  # the configurable-logger dispatch).
  @logger_functions [
    :log,
    :macro_log,
    :debug,
    :info,
    :notice,
    :warning,
    :error,
    :critical,
    :alert,
    :emergency
  ]

  @error_logger_functions [
    :error_msg,
    :info_msg,
    :warning_msg,
    :error_report,
    :info_report,
    :warning_report,
    :format
  ]

  @doc """
  Whether the region `visited` is straight-line code that builds and
  emits log lines and does nothing else that can raise: every call or
  raising instruction in it other than a log call produces a value that
  reaches a log call's arguments.
  """
  @spec log_region?(Enumerable.t(non_neg_integer()), tuple(), %{pos_integer() => pos_integer()}) ::
          boolean()
  def log_region?(visited, table, line_table) do
    set = MapSet.new(visited)

    with true <- map_size(line_table) > 0,
         [first | _] <- Enum.sort(visited),
         {:ok, main} <- main_path(first, set, table, []),
         on_main = MapSet.new(main),
         raising = MapSet.difference(set, on_main),
         true <- Enum.all?(raising, &raise_block?(elem(table, &1))),
         instrs = Enum.map(main, &{&1, elem(table, &1)}),
         true <- Enum.all?(instrs, fn {_at, instr} -> straight?(instr) end),
         {:ok, produced, consumed, logged?} <- flow(instrs, lines(instrs, line_table)) do
      logged? and MapSet.subset?(produced, consumed)
    else
      _ -> false
    end
  end

  # The region's path by fall-through from its first instruction to the
  # end of the try (`try_end`, or `catch_end` for Erlang's `catch`). A
  # branch off it may only go to code that raises (below): a record
  # access's `is_tagged_tuple` test fails into a `badrecord`.
  defp main_path(at, set, table, acc) do
    cond do
      not MapSet.member?(set, at) or at >= tuple_size(table) ->
        :error

      op(elem(table, at)) in [:try_end, :catch_end] ->
        {:ok, Enum.reverse([at | acc])}

      Argus.Instr.falls_through?(elem(table, at)) ->
        main_path(at + 1, set, table, [at | acc])

      true ->
        :error
    end
  end

  # The code off the main path: it builds an error and raises it, and
  # does nothing else. Such a branch is its instruction's way of raising.
  @raise_ops [:badrecord, :badmatch, :case_end, :if_end, :try_case_end, :raw_raise]

  defp raise_block?(instr) do
    op(instr) in @raise_ops or match?({:bif, :raise, _, _, _}, instr) or
      raising_call?(instr) or (inert?(instr) and Argus.Instr.targets(instr) == [])
  end

  defp raising_call?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, f, _} -> f in [:error, :exit, :throw, :raise]
      _ -> false
    end
  end

  # On the main path, a branch is a guard BIF's fail label or a test's,
  # which the region check above has sent to raising code: the flow reads
  # either as its instruction raising.
  defp straight?(instr) do
    Argus.Instr.known?(instr) and
      (Argus.Instr.targets(instr) == [] or guard?(instr)) and
      (Argus.Instr.falls_through?(instr) or op(instr) in [:try_end, :catch_end])
  end

  defp op(instr) when is_tuple(instr) and tuple_size(instr) > 0, do: elem(instr, 0)
  defp op(instr), do: instr

  defp guard?({:bif, _, _, _, _}), do: true
  defp guard?({:gc_bif, _, _, _, _, _}), do: true
  defp guard?({:test, _, _, _}), do: true
  defp guard?({:test, _, _, _, _}), do: true
  defp guard?(_instr), do: false

  # The source line each instruction of the region runs at: the last
  # line marker before it in the region (nil before the first).
  defp lines(instrs, line_table) do
    {map, _line} =
      Enum.reduce(instrs, {%{}, nil}, fn {at, instr}, {map, line} ->
        line =
          case instr do
            {:line, ref} -> Map.get(line_table, ref, line)
            _ -> line
          end

        {Map.put(map, at, line), line}
      end)

    map
  end

  # Walks the region in order, carrying for each register the producers
  # (indices of raising instructions) whose values it holds, and the
  # atoms moved into registers (an apply's function). Returns the
  # producers, the producers some log call read, and whether one ran.
  defp flow(instrs, lines) do
    Enum.reduce_while(instrs, {:ok, MapSet.new(), MapSet.new(), false, %{}, %{}}, fn
      {at, instr}, {:ok, produced, consumed, logged?, holds, atoms} ->
        read = instr |> Argus.Instr.uses() |> Enum.flat_map(&Map.get(holds, &1, []))
        read = MapSet.new(read)

        cond do
          log_call?(instr, atoms) ->
            holds = step(instr, holds, [])
            line = Map.get(lines, at)
            # A producer on an earlier line is a statement of its own.
            args =
              MapSet.filter(
                read,
                &(line != nil and Map.get(lines, &1) != nil and Map.get(lines, &1) >= line)
              )

            {:cont, {:ok, produced, MapSet.union(consumed, args), true, holds, %{}}}

          match?({:test, _, _, _}, instr) or match?({:test, _, _, _, _}, instr) ->
            # A test that can fail into raising code guards the values it
            # tests: they carry it, as a term built from them would.
            holds =
              Enum.reduce(Argus.Instr.uses(instr), holds, fn reg, acc ->
                Map.update(acc, reg, [at], &[at | &1])
              end)

            {:cont, {:ok, MapSet.put(produced, at), consumed, logged?, holds, atoms}}

          inert?(instr) ->
            {:cont,
             {:ok, produced, consumed, logged?, step(instr, holds, MapSet.to_list(read)),
              atoms(instr, atoms)}}

          true ->
            {:cont,
             {:ok, MapSet.put(produced, at), consumed, logged?,
              step(instr, holds, [at | MapSet.to_list(read)]), %{}}}
        end
    end)
    |> case do
      {:ok, produced, consumed, logged?, _holds, _atoms} -> {:ok, produced, consumed, logged?}
    end
  end

  # What each register holds after `instr`: carried copies keep theirs,
  # clobbered registers lose them, and what `instr` writes holds what it
  # read (a term built from a value carries it).
  defp step(instr, holds, read) do
    carried =
      for {reg, from} <- holds,
          reg in Argus.Instr.carry(instr, [reg]),
          into: %{},
          do: {reg, from}

    copies =
      for dst <- Argus.Instr.defs(instr),
          src = Argus.Instr.copy_source(instr, dst),
          src != nil,
          Map.has_key?(holds, src),
          into: %{},
          do: {dst, Map.fetch!(holds, src)}

    built =
      if read == [],
        do: %{},
        else:
          for(
            dst <- Argus.Instr.defs(instr),
            Argus.Instr.copy_source(instr, dst) == nil,
            into: %{},
            do: {dst, Enum.uniq(read)}
          )

    carried |> Map.merge(copies) |> Map.merge(built)
  end

  defp atoms({:move, {:atom, atom}, dst}, atoms),
    do: Map.put(atoms, Argus.Instr.register(dst), atom)

  defp atoms(instr, atoms) do
    defs = Argus.Instr.defs(instr)
    Map.drop(atoms, defs)
  end

  defp log_call?({:apply, arity}, atoms), do: Map.get(atoms, {:x, arity + 1}) == :log
  defp log_call?({:apply_last, arity, _}, atoms), do: Map.get(atoms, {:x, arity + 1}) == :log

  defp log_call?(instr, _atoms) do
    case Helpers.match_remote_call(instr) do
      {:ok, :logger, f, _} -> f in @logger_functions
      {:ok, :error_logger, f, _} -> f in @error_logger_functions
      {:ok, Logger, f, _} -> f in [:bare_log, :__do_log__]
      _ -> false
    end
  end

  @doc "Whether `instr` is an operation whose failure is another process's, a port's or a name's."
  @spec boundary?(tuple() | atom()) :: boolean()
  def boundary?(:send), do: true
  def boundary?({:send}), do: true

  def boundary?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, m, f, a} -> MapSet.member?(@boundary_calls, {m, f, a})
      :none -> false
    end
  end

  @doc "Whether `instr` cannot raise."
  @spec inert?(tuple() | atom()) :: boolean()
  def inert?({:bif, name, fail, _args, _dst}), do: name in @total_bifs or guarded?(fail)
  def inert?({:gc_bif, _name, fail, _live, _args, _dst}), do: guarded?(fail)
  def inert?(instr) when is_tuple(instr), do: elem(instr, 0) in @inert
  def inert?(_instr), do: false

  # A guard BIF jumps to its fail label instead of raising.
  defp guarded?({:f, label}), do: label != 0
  defp guarded?(_nofail), do: false
end
