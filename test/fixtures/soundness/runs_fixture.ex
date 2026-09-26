# Adversarial neighbours of the readings that narrow what the soundness
# of clientlib/runs.dl and the gen_statem extractor claims
# (docs/design/runs.md). test/soundness/runs_test.exs asserts each.

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
