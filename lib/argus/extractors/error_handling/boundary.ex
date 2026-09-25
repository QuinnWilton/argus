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
                    {:erpc, :call, 5}
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
  operation and nothing else that can raise.
  """
  @spec region?(Enumerable.t(non_neg_integer()), tuple()) :: boolean()
  def region?(visited, table) do
    instrs = Enum.map(visited, &elem(table, &1))
    Enum.any?(instrs, &boundary?/1) and Enum.all?(instrs, &(boundary?(&1) or inert?(&1)))
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
