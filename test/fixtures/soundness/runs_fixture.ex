# Adversarial neighbours of each narrowing of the once/again split (clientlib/runs.dl,
# docs/design/analysis-model.md#startup-and-repeated-execution) and of the gen_statem
# extractor's readings of a machine's states.
#
# A clause is once code only when every message that can enter it is
# made by its process's once code. Each module in the first groups has a
# clause some code that runs again, another process, or the clause itself
# can enter again, and takes a monitor there whose ref it throws away:
# the finding "Monitor taken again with its ref thrown away" must stay.
# The quiet controls beside them take the same monitor in a clause only
# once code enters. The gen_statem groups keep "No clause for a message a
# gen_statem is sent". test/soundness/runs_test.exs asserts each.

# ── A handle_info/2 or handle_cast/2 clause, by its message's producers ─

defmodule Argus.Test.Soundness.Runs.FromInitAndHandler do
  @moduledoc """
  init/1 sends `:watch` once, and the reconnect clause sends it again:
  the `:watch` clause runs on every reconnect.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    send(self(), :watch)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.FromInitAndOutside do
  @moduledoc """
  init/1 sends `:watch` once, and the module's API lets any caller send it
  again: another process is a producer the process cannot count.
  """
  use GenServer

  def rewatch(pid), do: send(pid, :watch)

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.Cycle do
  @moduledoc """
  init/1 sends `:ping` once, and the two clauses send each other round:
  each runs again and again, however it started.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :ping)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ping, state) do
    Process.send_after(self(), :pong, 1000)
    {:noreply, state}
  end

  def handle_info(:pong, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    send(self(), :ping)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.SharedSender do
  @moduledoc """
  The helper that sends `:watch` runs from init/1 and from a cast: a
  producer both once code and code that runs again reach.
  """
  use GenServer

  @impl true
  def init(_) do
    ask()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:again, state) do
    ask()
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  defp ask, do: send(self(), :watch)
end

defmodule Argus.Test.Soundness.Runs.Relay do
  @moduledoc """
  init/1 sends `:watch` once, and a handler sends itself whatever it is
  asked to: a message of any tag, `:watch` among them, from code that
  runs again.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info({:relay, message}, state) do
    send(self(), message)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.Interval do
  @moduledoc """
  init/1 arms `:watch` once, but on an interval: the timer sends it again
  and again.
  """
  use GenServer

  @impl true
  def init(_) do
    {:ok, _ref} = :timer.send_interval(1000, :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.DirectCall do
  @moduledoc """
  init/1 sends `:watch` once, and a cast runs the clause itself, handing
  handle_info/2 the message: no send, the same clause again.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:kick, state), do: handle_info(:watch, state)

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.Published do
  @moduledoc """
  init/1 sends `{:watch, _}` once and subscribes, and a publisher hands
  PubSub the same message: the library sends it from code the program
  does not show, on every publish.
  """
  use GenServer
  @compile {:no_warn_undefined, [Phoenix.PubSub]}

  def publish(x), do: Phoenix.PubSub.broadcast(:runs_pubsub, "watch", {:watch, x})

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(:runs_pubsub, "watch")
    send(self(), {:watch, nil})
    {:ok, %{}}
  end

  @impl true
  def handle_info({:watch, _}, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.OnceOnly do
  @moduledoc """
  Quiet: init/1 sends `:watch`, and nothing else does. Its clause runs
  once per incarnation, as init/1 does.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.OnceChain do
  @moduledoc """
  Quiet: init/1 casts `:load` to itself, whose clause arms `:watch` once:
  both clauses run once, one after the other.
  """
  use GenServer

  @impl true
  def init(_) do
    GenServer.cast(self(), :load)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:load, state) do
    Process.send_after(self(), :watch, 0)
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

# ── A handle_continue/2 clause, by the returns that continue to it ─────

defmodule Argus.Test.Soundness.Runs.ContinueAgain do
  @moduledoc """
  init/1 continues to `:setup`, and a reset continues to it again: the
  clause runs on every reset.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  @impl true
  def handle_info(:reset, state), do: {:noreply, state, {:continue, :setup}}
end

defmodule Argus.Test.Soundness.Runs.ContinueFromHelper do
  @moduledoc """
  init/1 continues to `:setup`, and a call returns a helper's
  `{:reply, :ok, state, {:continue, :setup}}`: the helper's return is the
  call's.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state), do: reload(state)

  defp reload(state), do: {:reply, :ok, state, {:continue, :setup}}
end

defmodule Argus.Test.Soundness.Runs.ContinueAny do
  @moduledoc """
  init/1 continues to `:setup`, and a handler continues to whatever it is
  handed: a continue of any tag, from code that runs again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  @impl true
  def handle_info({:next, step}, state), do: {:noreply, state, {:continue, step}}
end

defmodule Argus.Test.Soundness.Runs.ContinueOnce do
  @moduledoc "Quiet: only init/1 continues to `:setup`."
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

# ── A gen_statem's :internal clause, by the events inserted ────────────

defmodule Argus.Test.Soundness.Runs.InsertAgain do
  @moduledoc """
  init/1 inserts an `:internal` `:watch`, and a cast inserts it again:
  the internal clause runs on every cast.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, :rewatch, _state, data),
    do: {:keep_state, data, [{:next_event, :internal, :watch}]}
end

defmodule Argus.Test.Soundness.Runs.InsertAnyType do
  @moduledoc """
  init/1 inserts an `:internal` event, and a cast inserts one of the type
  it is handed (ra's `{next_event, EvtType, Evt}`): any type, `:internal`
  among them, from code that runs again.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, {:redo, type}, _state, data),
    do: {:keep_state, data, [{:next_event, type, :watch}]}
end

defmodule Argus.Test.Soundness.Runs.InsertShared do
  @moduledoc """
  The helper that inserts the `:internal` event runs from init/1 and from
  a cast.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, watch()}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, :rewatch, _state, data), do: {:keep_state, data, watch()}

  defp watch, do: [{:next_event, :internal, :watch}]
end

defmodule Argus.Test.Soundness.Runs.InsertOnce do
  @moduledoc """
  Quiet: only init/1 inserts the `:internal` event (sequin's
  TableReaderServer): the internal clause runs once.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, :ping, _state, data), do: {:keep_state, data}
end

defmodule Argus.Test.Soundness.Runs.InsertOnceBesideAnother do
  @moduledoc """
  Quiet: only init/1 inserts the `:internal` `:watch`; a cast inserts an
  `:internal` `:poll`, which another clause takes. A clause is told by its
  event's content as well as its type (issue #3), so the `:watch` clause
  runs once.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:internal, :poll, _state, data), do: {:keep_state, data}

  def handle_event(:cast, :poke, _state, data),
    do: {:keep_state, data, [{:next_event, :internal, :poll}]}
end

defmodule Argus.Test.Soundness.Runs.InsertAnyContent do
  @moduledoc """
  init/1 inserts the `:internal` `:watch`, and a cast inserts an
  `:internal` event of the content it is handed: any `:internal` clause,
  the `:watch` one among them, from code that runs again.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, :watch, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, {:redo, event}, _state, data),
    do: {:keep_state, data, [{:next_event, :internal, event}]}
end

defmodule Argus.Test.Soundness.Runs.InsertIntoAnyContent do
  @moduledoc """
  The monitoring clause takes `:internal` events of any content; init/1
  inserts one and a cast inserts a `:poll`, which it takes too.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}, [{:next_event, :internal, :watch}]}

  @impl true
  def handle_event(:internal, _any, _state, data) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:keep_state, data}
  end

  def handle_event(:cast, :poke, _state, data),
    do: {:keep_state, data, [{:next_event, :internal, :poll}]}
end

# ── The idle timeout's clause, by the returns that arm it ──────────────

defmodule Argus.Test.Soundness.Runs.TimeoutAgain do
  @moduledoc """
  init/1 arms the idle timeout, and a cast arms it again: the `:timeout`
  clause runs after every poke.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, 0}

  @impl true
  def handle_cast(:poke, state), do: {:noreply, state, 5000}

  @impl true
  def handle_info(:timeout, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.TimeoutUnspelled do
  @moduledoc """
  init/1 arms the idle timeout, and a cast returns a timeout its state
  holds: a value the return does not spell is a timeout too.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{interval: 1000}, 0}

  @impl true
  def handle_cast(:poke, state), do: {:noreply, state, state.interval}

  @impl true
  def handle_info(:timeout, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.TimeoutFromHelper do
  @moduledoc """
  init/1 arms the idle timeout, and a cast returns a helper's
  `{:noreply, state, 100}`.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, 0}

  @impl true
  def handle_cast(:poke, state), do: rearm(state)

  @impl true
  def handle_info(:timeout, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  defp rearm(state), do: {:noreply, state, 100}
end

defmodule Argus.Test.Soundness.Runs.TimeoutOnce do
  @moduledoc """
  Quiet: only init/1 arms the idle timeout (vernemq's vmq_cluster_mon):
  the `:timeout` clause runs once.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, 0}

  @impl true
  def handle_cast(:poke, state), do: {:noreply, state}

  @impl true
  def handle_info(:timeout, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

# ── A clause function a callback hands its message to ──────────────────

defmodule Argus.Test.Soundness.Runs.Shared do
  @moduledoc """
  The clauses two channels hand their messages to
  (`defdelegate handle_info(msg, s), to: Shared`), as firezone's
  PortalAPI.Client.Channel.Shared.
  """
  def join(state) do
    send(self(), :watch)
    {:ok, state}
  end

  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info(:rewatch, state) do
    send(self(), :watch)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Runs.DelegatingServer do
  @moduledoc """
  Hands every message on to Shared, whose `:rewatch` clause sends
  `:watch` again: the clause handed `:watch` runs again.
  """
  use GenServer

  @impl true
  def init(state), do: Argus.Test.Soundness.Runs.Shared.join(state)

  @impl true
  defdelegate handle_info(message, state), to: Argus.Test.Soundness.Runs.Shared
end

defmodule Argus.Test.Soundness.Runs.SharedOnce do
  @moduledoc """
  Quiet counterpart of Shared: only the start sends `:watch`.
  """
  def join(state) do
    send(self(), :watch)
    {:ok, state}
  end

  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Runs.DelegatingOnce do
  @moduledoc "Quiet: hands its messages to SharedOnce."
  use GenServer

  @impl true
  def init(state), do: Argus.Test.Soundness.Runs.SharedOnce.join(state)

  @impl true
  defdelegate handle_info(message, state), to: Argus.Test.Soundness.Runs.SharedOnce
end

defmodule Argus.Test.Soundness.Runs.CalledFromOutside do
  @moduledoc """
  A server whose `:watch` clause another module runs directly, handing it
  the message: the clause runs in that caller's process, as often as it
  calls.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.OutsideCaller do
  @moduledoc false
  def poke(state), do: Argus.Test.Soundness.Runs.CalledFromOutside.handle_info(:watch, state)
end

defmodule Argus.Test.Soundness.Runs.SharedB do
  @moduledoc "The clauses DelegateResend hands its messages to."
  def join(state) do
    send(self(), :watch)
    {:ok, state}
  end

  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Runs.DelegateResend do
  @moduledoc """
  Hands its messages to SharedB, and sends `:watch` again from a cast of
  its own: the shared clause runs on every cast.
  """
  use GenServer

  @impl true
  def init(state), do: Argus.Test.Soundness.Runs.SharedB.join(state)

  @impl true
  def handle_cast(:again, state) do
    send(self(), :watch)
    {:noreply, state}
  end

  @impl true
  defdelegate handle_info(message, state), to: Argus.Test.Soundness.Runs.SharedB
end

defmodule Argus.Test.Soundness.Runs.SharedC do
  @moduledoc "The clauses two servers hand their messages to."
  def join(state) do
    send(self(), :watch)
    {:ok, state}
  end

  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Runs.OwnerOnce do
  @moduledoc "Hands its messages to SharedC; only its start sends `:watch`."
  use GenServer

  @impl true
  def init(state), do: Argus.Test.Soundness.Runs.SharedC.join(state)

  @impl true
  defdelegate handle_info(message, state), to: Argus.Test.Soundness.Runs.SharedC
end

defmodule Argus.Test.Soundness.Runs.OwnerAgain do
  @moduledoc """
  Hands its messages to SharedC too, and sends `:watch` again from a
  cast: the shared clause runs again in this process, whatever the other
  does.
  """
  use GenServer

  @impl true
  def init(state), do: Argus.Test.Soundness.Runs.SharedC.join(state)

  @impl true
  def handle_cast(:again, state) do
    send(self(), :watch)
    {:noreply, state}
  end

  @impl true
  defdelegate handle_info(message, state), to: Argus.Test.Soundness.Runs.SharedC
end

# ── A gen_statem's states and catch-alls (the extractor) ───────────────
#
# "No clause for a message a gen_statem is sent" is judged where a state
# has no :info catch-all and no state takes the message. Two readings
# narrow it: a function an event is re-dispatched to is a state when a
# transition names it (its clauses take messages), and a clause that
# reaches a call has passed its head (a catch-all that hands the event
# on). Each machine here arms `:ping` for itself, and some state has no
# clause for it.

defmodule Argus.Test.Soundness.Runs.StatemContentThenCall do
  @moduledoc """
  `idle`'s :info clause takes one message and calls a helper: the call is
  past a head that asked the content, so `idle` has no :info catch-all.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:info, :tick, data) do
    tick(data)
    :keep_state_and_data
  end

  def idle(:cast, :go, data), do: {:keep_state, data}

  defp tick(data), do: Map.put(data, :ticked, true)
end

defmodule Argus.Test.Soundness.Runs.StatemCastCatchAll do
  @moduledoc """
  `idle` hands every cast to a helper, and has no :info clause at all: a
  catch-all for one event type is none for the others.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:cast, message, data) do
    handle(message)
    {:keep_state, data}
  end

  defp handle(message), do: Process.put(:last, message)
end

defmodule Argus.Test.Soundness.Runs.StatemGuardedCall do
  @moduledoc """
  `idle`'s generic clause is guarded on the event type (`when type ==
  :cast`) before it calls: a guard on the type is part of the head.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(type, message, data) when type == :cast do
    handle(message)
    {:keep_state, data}
  end

  defp handle(message), do: Process.put(:last, message)
end

defmodule Argus.Test.Soundness.Runs.StatemHelperNotNamed do
  @moduledoc """
  `busy` re-dispatches every event to `common/3`, which takes `:ping`,
  but no transition names `common`: it is a helper, not a state, and
  `idle` has no clause for `:ping`.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:cast, :go, data), do: {:next_state, :busy, data}

  def busy(type, message, data), do: common(type, message, data)

  def common(:info, :ping, data), do: {:keep_state, Map.put(data, :pinged, true)}
  def common(_type, _message, data), do: {:keep_state, data}
end

defmodule Argus.Test.Soundness.Runs.StatemHelperNamedAsMessage do
  @moduledoc """
  The helper `retry/3` takes `:ping`, and the module writes the atom
  `:retry` as a message, never as a transition's target: still a helper.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:cast, :go, data) do
    send(self(), :retry)
    {:next_state, :busy, data}
  end

  def busy(type, message, data), do: retry(type, message, data)

  def retry(:info, :ping, data), do: {:keep_state, Map.put(data, :pinged, true)}
  def retry(_type, _message, data), do: {:keep_state, data}
end

defmodule Argus.Test.Soundness.Runs.StatemDataFirst do
  @moduledoc """
  Redix's `disconnect(data, reason, flag)` shape: an exported arity-3
  function returning a transition, called with the data first. It takes
  `:ping` in its body, but no event is re-dispatched to it.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:cast, :go, data), do: disconnect(data, :go, false)
  def idle(:cast, :stay, data), do: {:keep_state, data}

  def disconnect(data, :ping, _flag), do: {:next_state, :idle, Map.put(data, :pinged, true)}
  def disconnect(data, _reason, _flag), do: {:next_state, :idle, data}
end

defmodule Argus.Test.Soundness.Runs.StatemRedispatchedState do
  @moduledoc """
  Quiet: ra's shape. `active` re-dispatches a rewritten event to itself
  and a transition names it, so it is a state, and its :info clause takes
  `:ping`; `idle` has no :info clause, but a message some state takes may
  be one the program sends only while the machine is in that state.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_), do: {:ok, :idle, %{}}

  def idle(:cast, :go, data) do
    Process.send_after(self(), :ping, 1000)
    {:next_state, :active, data}
  end

  def active(:info, :ping, data), do: {:keep_state, Map.put(data, :pinged, true)}
  def active(:cast, {:wrapped, message}, data), do: active(:cast, message, data)
  def active(:cast, _message, data), do: {:keep_state, data}
end

defmodule Argus.Test.Soundness.Runs.StatemDelegatingCatchAll do
  @moduledoc """
  Quiet: ra's `terminating_leader/3`. Its generic clause hands every event
  to another state and cases on what that returns: a catch-all, though
  the head is followed by tests of a call's result.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :draining, %{}}
  end

  def draining(:enter, _old, data), do: {:keep_state, data}

  def draining(type, message, data) do
    case active(type, message, data) do
      {:keep_state, next} -> {:keep_state, next}
      {:next_state, _state, next} -> {:keep_state, next}
    end
  end

  def active(:cast, :go, data), do: {:keep_state, data}
  def active(_type, _message, data), do: {:next_state, :draining, data}
end

defmodule Argus.Test.Soundness.Runs.LoopReturns do
  @moduledoc """
  What a callback's return asks of its loop, for the OTP extractor's
  tests: a continue, a timeout spelled and unspelled, and the values that
  are neither.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{wait: 10}, {:continue, {:load, 1}}}

  @impl true
  def handle_continue({:load, _n}, state), do: {:noreply, state, :hibernate}

  @impl true
  def handle_cast(:wait, state), do: {:noreply, state, state.wait}
  def handle_cast(:forever, state), do: {:noreply, state, :infinity}
  def handle_cast(:plain, state), do: {:noreply, state}

  @impl true
  def handle_call(:soon, _from, state), do: {:reply, :ok, state, 0}
end

defmodule Argus.Test.Soundness.Runs.StatemViaHelper do
  @moduledoc """
  `idle`'s every clause returns what a helper builds: a state all the
  same, whose missing :info clause the arm of `:ping` meets.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_) do
    Process.send_after(self(), :ping, 1000)
    {:ok, :idle, %{}}
  end

  def idle(:cast, message, data), do: handle(message, data)

  defp handle(message, data), do: {:keep_state, Map.put(data, :last, message)}
end

# ── A LiveView's handle_async/3 clause, by the start_async calls ───────

defmodule Argus.Test.Soundness.Runs.AsyncAgain do
  @moduledoc """
  mount/3 starts `:load`, and an event starts it again: the result's
  clause runs on every reload.
  """
  @behaviour Phoenix.LiveView
  @compile {:no_warn_undefined, [{Phoenix.LiveView, :start_async, 3}]}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, Phoenix.LiveView.start_async(socket, :load, fn -> :ok end)}

  @impl true
  def handle_event("reload", _params, socket),
    do: {:noreply, Phoenix.LiveView.start_async(socket, :load, fn -> :ok end)}

  @impl true
  def handle_async(:load, _result, socket) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, socket}
  end
end

defmodule Argus.Test.Soundness.Runs.AsyncAnyName do
  @moduledoc """
  mount/3 starts `:load`, and an event starts a task under whatever name
  it is handed: any name, `:load` among them.
  """
  @behaviour Phoenix.LiveView
  @compile {:no_warn_undefined, [{Phoenix.LiveView, :start_async, 3}]}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, Phoenix.LiveView.start_async(socket, :load, fn -> :ok end)}

  @impl true
  def handle_event("start", %{"name" => name}, socket),
    do:
      {:noreply,
       Phoenix.LiveView.start_async(socket, String.to_existing_atom(name), fn -> :ok end)}

  @impl true
  def handle_async(:load, _result, socket) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, socket}
  end
end

defmodule Argus.Test.Soundness.Runs.AsyncShared do
  @moduledoc "The helper that starts `:load` runs from mount/3 and from a message."
  @behaviour Phoenix.LiveView
  @compile {:no_warn_undefined, [{Phoenix.LiveView, :start_async, 3}]}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_async(:load, _result, socket) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, socket}
  end

  defp load(socket), do: Phoenix.LiveView.start_async(socket, :load, fn -> :ok end)
end

defmodule Argus.Test.Soundness.Runs.AsyncOnce do
  @moduledoc """
  Quiet: only mount/3 starts `:run` (Lightning's RunLive): the result's
  clause runs once per LiveView process.
  """
  @behaviour Phoenix.LiveView
  @compile {:no_warn_undefined, [{Phoenix.LiveView, :start_async, 3}]}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, Phoenix.LiveView.start_async(socket, :run, fn -> :ok end)}

  @impl true
  def handle_event("ping", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:run, _result, socket) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, socket}
  end
end

# ── Producers no known root reaches ────────────────────────────────────

defmodule Argus.Test.Soundness.Runs.RunsFuns do
  @moduledoc """
  init/1 sends `:watch` once, and a call runs whatever fun it is handed:
  a fun FunSender builds to send `:watch`, run on this process's stack.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.FunSender do
  @moduledoc false
  def kick(pid), do: GenServer.call(pid, {:run, fn -> send(self(), :watch) end})
end

defmodule Argus.Test.Soundness.Runs.CallsHooks do
  @moduledoc """
  init/1 sends `:watch` once, and a cast runs the hook module its state
  names: Hooks.refresh/0, which no program code calls, runs here and sends
  `:watch` again.
  """
  use GenServer

  @impl true
  def init(_) do
    send(self(), :watch)
    {:ok, %{hooks: Argus.Test.Soundness.Runs.Hooks}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state.hooks.refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch, state) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.Hooks do
  @moduledoc false
  def refresh, do: send(self(), :watch)
end

defmodule Argus.Test.Soundness.Runs.ComponentUpdate do
  @moduledoc """
  A LiveComponent's update/2 runs on every render of its parent, and
  starts `:load` each time: its library calls it where it runs the
  component's handle_async/3.
  """
  @behaviour Phoenix.LiveComponent
  @compile {:no_warn_undefined, [{Phoenix.LiveView, :start_async, 3}]}

  @impl true
  def update(_assigns, socket),
    do: {:ok, Phoenix.LiveView.start_async(socket, :load, fn -> :ok end)}

  @impl true
  def handle_async(:load, _result, socket) do
    Process.monitor(Process.whereis(:runs_upstream))
    {:noreply, socket}
  end
end

# ── What reads the split: timer loops and subscriptions ────────────────

defmodule Argus.Test.Soundness.Runs.ContinueResubscribes do
  @moduledoc """
  A reset continues to `:subscribe`, whose clause subscribes: the clause
  runs on every reset, and each run adds a subscription.
  """
  use GenServer
  @compile {:no_warn_undefined, [Phoenix.PubSub]}

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :subscribe}}

  @impl true
  def handle_continue(:subscribe, state) do
    Phoenix.PubSub.subscribe(:runs_pubsub, "jobs")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset, state), do: {:noreply, state, {:continue, :subscribe}}
end

defmodule Argus.Test.Soundness.Runs.ContinueRearms do
  @moduledoc """
  A periodic `:tick` loop, and a reset that continues to a clause arming
  `:tick` again beside the pending one.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :start}}

  @impl true
  def handle_continue(:start, state) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset, state), do: {:noreply, state, {:continue, :start}}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Runs.SubscribesOnce do
  @moduledoc """
  Quiet: only init/1 continues to `:subscribe`, whose clause subscribes
  once per incarnation.
  """
  use GenServer
  @compile {:no_warn_undefined, [Phoenix.PubSub]}

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :subscribe}}

  @impl true
  def handle_continue(:subscribe, state) do
    Phoenix.PubSub.subscribe(:runs_pubsub, "jobs")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:ping, state), do: {:noreply, state}
end

# ── Coupling: a request the once phase makes ───────────────────────────
#
# Coupling reports a request a child's once code makes that a sibling
# keeps: a restart of the sibling alone loses it. Once code there is what
# may run in the once phase: a clause that runs once, and the start's
# continue chain, whatever else continues to it too — the request the
# start makes there may not be made again.

defmodule Argus.Test.Soundness.Runs.Keeper do
  @moduledoc "Keeps a monitor on every process that joins it."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def join(pid), do: GenServer.call(__MODULE__, {:join, pid})

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:join, pid}, _from, s) do
    Process.monitor(pid)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({:DOWN, _, :process, _, _}, s), do: {:noreply, s}
end

defmodule Argus.Test.Soundness.Runs.ContinueAlsoFromHandler do
  @moduledoc """
  jackalope's Hare: init/1 continues to `:join`, and a reconnect continues
  to it again. The start's join is made in the once phase, and a restart
  of the keeper alone loses it until the next reconnect, if any.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :join}}

  @impl true
  def handle_continue(:join, s) do
    :ok = Argus.Test.Soundness.Runs.Keeper.join(self())
    {:noreply, s}
  end

  @impl true
  def handle_cast(:reconnected, s), do: {:noreply, s, {:continue, :join}}
end

defmodule Argus.Test.Soundness.Runs.ContinueAlsoFromHandlerSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Soundness.Runs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Runs.Keeper, Runs.ContinueAlsoFromHandler], strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Runs.ContinueChain do
  @moduledoc """
  init/1 continues to `:prepare`, whose clause continues to `:join`, and a
  reconnect continues to `:join` again: the start's continue chain runs
  `:join`'s clause as part of the start.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :prepare}}

  @impl true
  def handle_continue(:prepare, s), do: {:noreply, s, {:continue, :join}}

  def handle_continue(:join, s) do
    :ok = Argus.Test.Soundness.Runs.Keeper.join(self())
    {:noreply, s}
  end

  @impl true
  def handle_cast(:reconnected, s), do: {:noreply, s, {:continue, :join}}
end

defmodule Argus.Test.Soundness.Runs.ContinueChainSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Soundness.Runs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Runs.Keeper, Runs.ContinueChain], strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Runs.ChainFromInit do
  @moduledoc """
  init/1 casts itself `:load`, whose clause continues to `:join`: a chain
  of clauses the start's messages enter, the last of which joins.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    GenServer.cast(self(), :load)
    {:ok, nil}
  end

  @impl true
  def handle_cast(:load, s), do: {:noreply, s, {:continue, :join}}

  @impl true
  def handle_continue(:join, s) do
    :ok = Argus.Test.Soundness.Runs.Keeper.join(self())
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Runs.ChainFromInitSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Soundness.Runs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Runs.Keeper, Runs.ChainFromInit], strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Runs.ContinueOnlyFromHandler do
  @moduledoc """
  Quiet: Livebook's NotebookManager `:dump_state`. Only a handler
  continues to `:join`: a join made on each use, which the next use makes
  again.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_continue(:join, s) do
    :ok = Argus.Test.Soundness.Runs.Keeper.join(self())
    {:noreply, s}
  end

  @impl true
  def handle_cast(:changed, s), do: {:noreply, s, {:continue, :join}}
end

defmodule Argus.Test.Soundness.Runs.ContinueOnlyFromHandlerSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Soundness.Runs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Runs.Keeper, Runs.ContinueOnlyFromHandler], strategy: :one_for_one)
end
