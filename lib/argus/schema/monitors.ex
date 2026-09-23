defmodule Argus.Schema.Monitors do
  @moduledoc """
  Monitors: where one is taken, whether its reference is kept, the
  `:DOWN` messages a callback matches, and how one is removed.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
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
      }
    ]
  end
end
