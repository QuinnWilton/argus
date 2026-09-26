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
  alias Argus.Purity.Effects

  # Calls whose failure is the state of something else: a process, a
  # node, a port, a registered name. The first four are :erlang BIFs a
  # call_ext names (a send written `send/2` compiles to the `send`
  # instruction, below). The premise is that the peer logged its own
  # crash, and what reaches the caller is a dead peer, a timeout or a
  # taken name. Two calls break it and are not here: `:erpc.call/4,5`
  # hands the caller the remote function's own exception, logged by
  # nobody (a KeyError in the program's code on the other node), and
  # Elixir's `Supervisor.start_child/2` builds the child spec in the
  # caller (`Supervisor.child_spec/2`), raising ArgumentError there for
  # a module with no child_spec/1: the program's own bug, in its own
  # process.
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
                    {Supervisor, :terminate_child, 2},
                    {Supervisor, :delete_child, 2},
                    {Supervisor, :restart_child, 2},
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
  a one-hop client API. Returns and tail calls end it. A function whose
  clause heads can fail — a guard (`when is_pid(pid)`) or an argument it
  dispatches on (`query(:primary, q)`), any test or select that fails to
  its `func_info` — raises FunctionClauseError in its caller for an
  argument nothing takes: the caller's own bug, which a try around the
  call must not be excused for swallowing.
  """
  @spec function?([tuple() | atom()]) :: boolean()
  def function?(instrs) do
    body = Enum.reject(instrs, &(&1 == :return or match?({:func_info, _, _, _}, &1)))

    Enum.any?(body, &boundary_op?/1) and
      Enum.all?(body, &(boundary_op?(&1) or inert?(&1))) and
      not clause_can_fail?(instrs)
  end

  # The label of the function's `func_info` (the one just before it) is
  # the target of a clause head that does not match.
  defp clause_can_fail?(instrs) do
    case clause_error_label(instrs) do
      nil -> false
      label -> Enum.any?(instrs, &(label in Argus.Instr.targets(&1)))
    end
  end

  defp clause_error_label([{:label, label}, {:func_info, _, _, _} | _rest]), do: label
  defp clause_error_label([_instr | rest]), do: clause_error_label(rest)
  defp clause_error_label([]), do: nil

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
  #
  # And every such producer is pure (`Argus.Purity.Effects`: a pure
  # call, a formatting protocol such as `inspect/2`, a pure BIF, a
  # guard test): real work inside the arguments —
  # `:logger.info("~p", [apply_entry!(t, e)])`, or an Erlang
  # do-and-log macro whose whole expansion shares its use's line — is
  # the program's own logic, and a catch-all around it turns its bug
  # into silence. A call into the program, a fun built in the region or
  # a call through one is not pure. The one exception is the module an
  # apply dispatches to: a getter with no arguments may pick it (ra's
  # `(ra_env:logger_mod()):log(...)`).
  #
  # The log call is a logger API — the logging modules of the effect
  # model (`Argus.Purity.Effects`: `:logger`, `:error_logger`, `Logger`,
  # the side paths calls.dl's side_api names too), at the functions that
  # emit a line — or an apply of `log` shaped as the logger's own
  # `log(Level, ...)`, its first argument a log level: the
  # configurable-logger dispatch. An apply of `log` on anything else
  # (`wal.log(entry)`, a write-ahead log's durable append) is work.
  @log_levels [
    :emergency,
    :alert,
    :critical,
    :error,
    :warning,
    :warn,
    :notice,
    :info,
    :debug
  ]

  # The functions of the logging modules that emit a line (and Elixir's
  # Logger macros' expansion), not the ones that configure the logger.
  @emitting %{
    logger: [:log, :macro_log | @log_levels],
    error_logger: [
      :error_msg,
      :info_msg,
      :warning_msg,
      :error_report,
      :info_report,
      :warning_report,
      :format
    ],
    "Elixir.Logger": [:bare_log, :__do_log__]
  }

  @doc """
  Whether the region `visited` is straight-line code that builds and
  emits log lines and does nothing else that can raise: every call or
  raising instruction in it other than a log call is pure and produces a
  value that reaches a log call's arguments.
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
         false <- Enum.any?(instrs, &match?({_at, {:make_fun3, _, _, _, _, _}}, &1)),
         {:ok, flow} <- flow(instrs, lines(instrs, line_table)) do
      flow.logged? and
        Enum.all?(flow.produced, fn at ->
          instr = elem(table, at)

          cond do
            MapSet.member?(flow.args, at) -> pure?(instr)
            MapSet.member?(flow.module, at) -> pure?(instr) or getter?(instr)
            true -> false
          end
        end)
    else
      _ -> false
    end
  end

  # A producer that does no work of its own: a guard test, a pure BIF, a
  # pure call or a formatting protocol (`Argus.Purity.Effects`). A call
  # into the program, or through a fun, is not.
  defp pure?({:test, _, _, _}), do: true
  defp pure?({:test, _, _, _, _}), do: true
  defp pure?({:bif, name, _fail, args, _dst}), do: pure_call?(:erlang, name, length(args))

  defp pure?({:gc_bif, name, _fail, _live, args, _dst}),
    do: pure_call?(:erlang, name, length(args))

  defp pure?(instr) do
    cond do
      match?({:ok, _, _, _}, Helpers.match_remote_call(instr)) ->
        {:ok, m, f, a} = Helpers.match_remote_call(instr)
        pure_call?(m, f, a)

      Argus.Instr.call?(instr) or Argus.Instr.tail_call?(instr) ->
        false

      true ->
        true
    end
  end

  defp pure_call?(m, f, a) do
    case Effects.classify(inspect(m), to_string(f), a) do
      :pure -> true
      {:opaque, :protocol} -> true
      _ -> false
    end
  end

  # A call with no arguments: a getter, which may pick an apply's module.
  defp getter?(instr) do
    case {Helpers.match_remote_call(instr), Helpers.match_local_call(instr)} do
      {{:ok, _m, _f, 0}, _} -> true
      {_, {:ok, _m, _f, 0}} -> true
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
  # atoms moved into registers (an apply's function, a level). Returns
  # the producers, the ones some log call read as an argument, the ones
  # it read only as the module an apply dispatches to, and whether one
  # ran.
  defp flow(instrs, lines) do
    init = %{produced: MapSet.new(), args: MapSet.new(), module: MapSet.new(), logged?: false}

    {flow, _holds, _atoms} =
      Enum.reduce(instrs, {init, %{}, %{}}, fn {at, instr}, {flow, holds, atoms} ->
        held = fn regs ->
          regs |> Enum.flat_map(&Map.get(holds, &1, [])) |> MapSet.new()
        end

        read = held.(Argus.Instr.uses(instr))

        cond do
          log_call?(instr, atoms) ->
            line = Map.get(lines, at)
            {arg_regs, module_regs} = log_operands(instr)
            # A producer on an earlier line is a statement of its own.
            same_line =
              &MapSet.filter(
                &1,
                fn p -> line != nil and Map.get(lines, p) != nil and Map.get(lines, p) >= line end
              )

            flow = %{
              flow
              | args: MapSet.union(flow.args, same_line.(held.(arg_regs))),
                module: MapSet.union(flow.module, same_line.(held.(module_regs))),
                logged?: true
            }

            {flow, step(instr, holds, []), %{}}

          match?({:test, _, _, _}, instr) or match?({:test, _, _, _, _}, instr) ->
            # A test that can fail into raising code guards the values it
            # tests: they carry it, as a term built from them would.
            holds =
              Enum.reduce(Argus.Instr.uses(instr), holds, fn reg, acc ->
                Map.update(acc, reg, [at], &[at | &1])
              end)

            {%{flow | produced: MapSet.put(flow.produced, at)}, holds, atoms}

          inert?(instr) ->
            {flow, step(instr, holds, MapSet.to_list(read)), atoms(instr, atoms)}

          true ->
            {%{flow | produced: MapSet.put(flow.produced, at)},
             step(instr, holds, [at | MapSet.to_list(read)]), %{}}
        end
      end)

    {:ok, flow}
  end

  # The registers a log call reads as its arguments, and the one an
  # apply reads as the module it dispatches to.
  defp log_operands({:apply, arity}), do: {x_regs(arity), [{:x, arity}]}
  defp log_operands({:apply_last, arity, _}), do: {x_regs(arity), [{:x, arity}]}
  defp log_operands(instr), do: {Argus.Instr.uses(instr), []}

  defp x_regs(0), do: []
  defp x_regs(arity), do: for(n <- 0..(arity - 1), do: {:x, n})

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

  defp log_call?({:apply, arity}, atoms), do: logger_apply?(arity, atoms)
  defp log_call?({:apply_last, arity, _}, atoms), do: logger_apply?(arity, atoms)

  defp log_call?(instr, _atoms) do
    case Helpers.match_remote_call(instr) do
      {:ok, m, f, a} -> f in Map.get(@emitting, m, []) and logging_module?(m, f, a)
      _ -> false
    end
  end

  # `Mod:log(Level, ...)`: the function is `log`, and its first argument
  # a log level.
  defp logger_apply?(arity, atoms) do
    arity >= 2 and Map.get(atoms, {:x, arity + 1}) == :log and
      Map.get(atoms, {:x, 0}) in @log_levels
  end

  defp logging_module?(m, f, a),
    do: match?({:impure, :logging, _}, Effects.classify(inspect(m), to_string(f), a))

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
