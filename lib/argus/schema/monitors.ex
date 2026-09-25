defmodule Argus.Schema.Monitors do
  @moduledoc """
  Monitors: where one is taken, whether its reference is kept, the
  `:DOWN` messages a callback or a receive matches, and how one is
  removed.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :monitor_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the call site"},
          {:func, :symbol, "the monitoring function"},
          {:target, :symbol,
           "the monitored name, 'started_child' when the pid came from a supervisor start, or 'dynamic'"}
        ],
        doc: """
        A `Process.monitor/1` or `:erlang.monitor/2`. Once it returns, a \
        `{:DOWN, ref, :process, object, reason}` arrives unless cancelled — so \
        a process that monitors is a process that receives `:DOWN`.
        """
      },
      %{
        name: :monitor_ref_dropped,
        layer: 2,
        fields: [
          {:id, :symbol, "the monitor call site"},
          {:func, :symbol, "the monitoring function"}
        ],
        doc: """
        The reference `Process.monitor/1` returned at this site is discarded: \
        the next thing to happen to the result register is a write that does \
        not read it. Nothing can ever demonitor this monitor; it ends only \
        when the monitored process does.
        """
      },
      %{
        name: :matches_down,
        layer: 2,
        fields: [{:func, :symbol, "a function whose clause heads compare an argument to :DOWN"}],
        doc: """
        The function handles (part of) a :DOWN message: an argument register, \
        or one projected from it, is compared to :DOWN in a clause head. \
        Emitted for every function rather than only named callbacks, because \
        a gen_statem funnels :info events through private helpers.
        """
      },
      %{
        name: :recv_down,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"},
          {:monitor, :symbol, "the monitor call whose :DOWN a clause takes"}
        ],
        doc: """
        A receive with a clause that takes the `:DOWN` of a monitor its own \
        function took: the pattern is `{:DOWN, ^ref, ...}` with `ref`, on every \
        path, the reference that monitor call returned, and nothing else in \
        the clause can refuse that message (a pin on the object, a reason, \
        a guard). No path from the monitor to the receive demonitors. The \
        runtime delivers that `:DOWN` once the process exits, or at once if \
        it was already gone, so the receive cannot outlast the monitored \
        process; its other clauses can only end it sooner.
        """
      },
      %{
        name: :recv_signal,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"},
          {:signal, :symbol, "'down' | 'exit'"}
        ],
        doc: """
        A receive with a clause that takes the exit signal of the process \
        a pinned register names, whatever the reason it exits with \
        (`Argus.Extractors.Monitor.ExitSignal`): a `:DOWN` whose ref the \
        clause pins (`"down"`; the tag may be a monitor's own, \
        `{alias, ^ref, :process, _, _}`) or an `:EXIT` whose sender it \
        pins (`"exit"`). Unlike recv_down, the pinned value may come from \
        anywhere: a parameter, a `spawn_monitor`'s pair, a port the \
        function opened. The receive ends no later than that process, \
        while the monitor or the link is in place. A clause that tests \
        the reason, or pins nothing, is not one.
        """
      },
      %{
        name: :demonitor_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the call site"},
          {:func, :symbol, "the cancelling function"},
          {:flush, :symbol, "'flush' | 'no_flush'"}
        ],
        doc: """
        A `Process.demonitor/1,2`. `flush` records whether `[:flush]` was \
        passed, which is the difference between cancelling a future message and \
        removing one already in the mailbox. Unreadable options are recorded as \
        `no_flush`, the direction that keeps a finding rather than discharging \
        one on a guess.
        """
      },
      %{
        name: :awaits_down_after,
        layer: 2,
        fields: [
          {:func, :symbol, "the calling function"},
          {:call, :symbol, "a call in it that returns"}
        ],
        doc: """
        Every path in `func` from the call at `call` to its return waits for \
        a :DOWN: a receive with no `after` whose `{:DOWN, ...}` clause takes \
        any monitor's, or the one whose ref the call returned; a \
        `Process.demonitor(ref, [:flush])` of that ref; or a call to a \
        function of the module that holds such a receive or calls one. A \
        monitor the callee left live is the caller's to collect: OTP's old \
        supervisor shutdown monitors each child, looks once (`after 0`) for \
        an exit already queued, and returns, and its caller then waits for \
        every child's :DOWN. A path that raises is not asked; a wait in a \
        closure or another module is not seen.
        """
      }
    ])
  end
end
