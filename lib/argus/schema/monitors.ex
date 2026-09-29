defmodule Argus.Schema.Monitors do
  @moduledoc """
  Layer-2 monitor facts: monitored targets, reference storage, `:DOWN` handlers, and \
  demonitoring. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :monitor_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the call site"},
          {:func, :symbol, "the monitoring function"},
          {:target, :symbol, "the monitored name when literal, or 'dynamic'"}
        ],
        doc: """
        A `Process.monitor/1` or `:erlang.monitor/2` call. Unless cancelled, a process \
        monitor delivers `{:DOWN, ref, :process, object, reason}` when its target exits.
        """
      },
      %{
        name: :monitor_type,
        layer: 2,
        fields: [
          {:id, :symbol, "the monitor_call site"},
          {:type, :symbol, "'process' | 'port' | 'time_offset', or 'dynamic'"}
        ],
        doc: """
        The monitor's target type and resulting message: process or port monitors send \
        `:DOWN`; `:time_offset` sends `:CHANGE`. Unresolved type arguments use \
        `dynamic`.
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
        A monitor reference overwritten before its first read. The program cannot \
        demonitor using that reference.
        """
      },
      %{
        name: :monitor_answer,
        layer: 2,
        fields: [
          {:id, :symbol, "the monitor call site"},
          {:func, :symbol, "the monitoring function"},
          {:call, :symbol, "a call whose answer the pid may be"},
          {:depth, :number, "0: the pid is the answer itself; 1: the pid of its `{:ok, pid}`"}
        ],
        doc: """
        Every possible call result supplying the monitored pid, at payload `depth` \
        (`Argus.Extractor.Answers`). Rows are all-or-nothing across paths. \
        `clientlib/answers.dl` determines whether the calls start processes. Deeper \
        nested pids, such as `{:error, {:already_started, pid}}`, leave the site without \
        rows.
        """
      },
      %{
        name: :monitor_kept,
        layer: 2,
        fields: [
          {:id, :symbol, "the monitor call site"},
          {:func, :symbol, "the monitoring function"},
          {:kind, :symbol, "'field' | 'table' | 'returned'"},
          {:where, :symbol,
           "the field's key, the table write's site, or for returned the element " <>
             "of the returned tuple that holds it ({i}), '' for anywhere"},
          {:holds, :symbol, "'ref' when made of the ref, 'pid' when made whole of the pid alone"}
        ],
        doc: """
        Where a monitor reference or monitored pid is stored: a returned state `field`, \
        an ETS operation (`table`), or a returned value (`returned`, optionally a tuple \
        element). `holds` distinguishes a stored reference from a pid-only record. Pid \
        storage requires the whole pid, not another part of its source message. \
        `returns_from` and `returned_field_from` trace storage through helpers.
        """
      },
      %{
        name: :awaits_child_exit,
        layer: 2,
        fields: [{:func, :symbol, "the function"}],
        doc: """
        Every start or spawn is followed on every returning path by a receive clause \
        accepting its monitor's `:DOWN`, or any monitor's `:DOWN`. Other receive clauses \
        and timeout arms do not qualify; raising paths are excluded. Establishes that \
        started children cannot outlive the call.
        """
      },
      %{
        name: :matches_down,
        layer: 2,
        fields: [{:func, :symbol, "a function whose clause heads compare an argument to :DOWN"}],
        doc: """
        A function matching `:DOWN` in an argument or projected value. Includes private \
        helpers as well as callbacks.
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
        A receive clause accepting every reason for `:DOWN` from a monitor created in \
        the same function. The pinned reference must come from that monitor on every \
        path, with no intervening demonitor. Other restrictions on the message \
        disqualify it. The receive cannot outlast the monitored process.
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
        A receive clause accepting every exit reason for a pinned monitor reference \
        (`down`, including custom tags) or sender (`exit`). The pinned value may come \
        from outside the function. A possible preceding demonitor excludes `down` rows. \
        The receive is bounded by the target's lifetime while the monitor or link \
        remains active.
        """
      },
      %{
        name: :recv_takes_exit,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"}
        ],
        doc: """
        A receive clause that may accept a trapped exit: its head fixes tag `:EXIT` or \
        leaves the tag unrestricted. Atom patterns and other fixed tags are excluded. \
        Tuple arity is not checked.
        """
      },
      %{
        name: :recv_flush,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"},
          {:cancel, :symbol, "the cancel_timer call whose false result it runs under"}
        ],
        doc: """
        A receive reached only after the earlier `cancel_timer` at `cancel` returns \
        `false`. Every path must take that result's false branch. An unchecked \
        cancellation does not qualify because a successful cancellation prevents message \
        delivery.
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
        A demonitor call and whether `[:flush]` is present. Flushing removes an already \
        queued `:DOWN`; cancellation alone does not. Unresolved options use `no_flush` \
        so they cannot suppress a finding.
        """
      },
      %{
        name: :monitor_released_after,
        layer: 2,
        fields: [
          {:func, :symbol, "the calling function"},
          {:call, :symbol, "a call in it that returns"}
        ],
        doc: """
        Every returning path after `call` releases its monitor by consuming the matching \
        `:DOWN`, demonitoring its reference, or calling a same-module helper recognized \
        as collecting on every return. Other receive clauses and timeout arms leave the \
        monitor live. Demonitoring need not flush; queued messages are checked \
        separately. Raising paths, closures, and cross-module waits are excluded.
        """
      },
      %{
        name: :recv_takes_down,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"}
        ],
        doc: """
        A receive clause with fixed tag `:DOWN`, regardless of restrictions on \
        reference, object, or reason. Catch-alls do not qualify.
        """
      }
    ])
  end
end
