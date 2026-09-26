# Adversarial neighbours of each narrowing of "once by the state"
# (clientlib/runs.dl's gated_once_site, Argus.Extractors.StateGate,
# docs/design/runs.md).
#
# A GenServer handler's site runs at most once per incarnation when a
# test of a field of the state lets it run only for some atoms, every way
# the handler completes after it sets the field outside them, nothing
# the module returns sets it back, and nothing in the program calls the
# handler. Each module below takes a monitor whose ref it throws away,
# behind a test whose other arm raises (so no other clause of the state
# decides it): "Monitor taken again with its ref thrown away" must stay
# wherever one condition fails. The quiet neighbours meet all four.
# test/soundness/gated_once_test.exs asserts each.

# ── The gate: the site runs only while the field holds the atom ────────

defmodule Argus.Test.Soundness.Gated.Flag do
  @moduledoc """
  Attaches once: the head admits `attached: false`, the clause's return
  sets it to `true`, and no return sets it back.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  def handle_cast(:ping, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Gated.NilOwner do
  @moduledoc """
  Attaches once: `if state.owner` raises unless the owner is nil or
  false, and the return sets a fresh ref, which no atom is.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{owner: nil}}

  @impl true
  def handle_cast(:attach, state) do
    if state.owner do
      raise "attached already"
    end

    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | owner: make_ref()}}
  end
end

defmodule Argus.Test.Soundness.Gated.Status do
  @moduledoc """
  Boots once: `case state.status` takes only `:idle`, and the return sets
  `:running`.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{status: :idle}}

  @impl true
  def handle_cast(:boot, state) do
    case state.status do
      :idle ->
        Process.monitor(Process.whereis(:gated_upstream))
        {:noreply, %{state | status: :running}}
    end
  end
end

defmodule Argus.Test.Soundness.Gated.MonitorBeforeTest do
  @moduledoc """
  The monitor comes before the test: every `:attach` takes it, and only
  then does a second one raise.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, state) do
    Process.monitor(Process.whereis(:gated_upstream))

    if state.attached do
      raise "attached already"
    end

    {:noreply, %{state | attached: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.NestedField do
  @moduledoc """
  The test reads a field of a map the state holds, not of the state: the
  gate is not read, and the site runs again as far as this shows.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{conn: %{attached: false}}}

  @impl true
  def handle_cast(:attach, state) do
    if state.conn.attached do
      raise "attached already"
    end

    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | conn: %{state.conn | attached: true}}}
  end
end

defmodule Argus.Test.Soundness.Gated.MapGet do
  @moduledoc """
  The field is read with `Map.get/2`, a call's answer, not the field
  itself: no gate.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, state) do
    if Map.get(state, :attached) do
      raise "attached already"
    end

    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.MessageField do
  @moduledoc """
  The head tests the message, not the state: whoever sends
  `{:attach, true}` runs the site, as often as it is sent.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, true}, state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end
end

# ── Closed: every way the handler completes after the site ───────────

defmodule Argus.Test.Soundness.Gated.OtherField do
  @moduledoc """
  The head tests `attached`, the return sets `ready`: `attached` stays
  false, and the next `:attach` passes the gate again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false, ready: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | ready: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.SomeReturns do
  @moduledoc """
  One way out sets the field, the other hands the state back as it came:
  the gate stays open on that one.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, confirm?}, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))

    if confirm? do
      {:noreply, %{state | attached: true}}
    else
      {:noreply, state}
    end
  end
end

defmodule Argus.Test.Soundness.Gated.Throws do
  @moduledoc """
  A throw after the monitor: gen_server takes the thrown value as the
  handler's result, and it hands the state back unchanged.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, early?}, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))

    if early? do
      throw({:noreply, state})
    end

    {:noreply, %{state | attached: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.RethrowsCaught do
  @moduledoc """
  A catch hands what it took back to `:erlang.raise/3` with its own
  class: a throw goes on as a throw, which gen_server takes as the
  handler's result.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, work}, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))

    try do
      work.()
    catch
      kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
    end

    {:noreply, %{state | attached: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.RescueKeeps do
  @moduledoc """
  The monitor is inside a `try` whose rescue hands the state back as it
  came: a raise after the monitor leaves the gate open.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, value}, %{attached: false} = state) do
    try do
      Process.monitor(Process.whereis(:gated_upstream))
      {:noreply, %{state | attached: check(value)}}
    rescue
      _ -> {:noreply, state}
    end
  end

  defp check(value) when is_boolean(value), do: true
end

defmodule Argus.Test.Soundness.Gated.MessageValue do
  @moduledoc """
  The return sets the field to what the message carries, which may be
  `false` again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast({:attach, value}, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: value}}
  end
end

defmodule Argus.Test.Soundness.Gated.ClosedByHelper do
  @moduledoc """
  The return hands the state to a helper that sets the field: closed
  through the helper.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, mark(state)}
  end

  defp mark(state), do: %{state | attached: true}
end

defmodule Argus.Test.Soundness.Gated.ClosedByStop do
  @moduledoc """
  The handler stops the process after the monitor: nothing runs after.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:stop, :normal, state}
  end
end

defmodule Argus.Test.Soundness.Gated.ClaimedByCaller do
  @moduledoc """
  A claim taken while `worker: nil`, setting the caller's pid from
  `from`, which no atom is (honeydew's JobMonitor).
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{worker: nil}}

  @impl true
  def handle_call(:claim, {worker, _tag}, %{worker: nil} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:reply, :ok, %{state | worker: worker}}
  end
end

# ── Nothing the module returns sets the field back ───────────────────

defmodule Argus.Test.Soundness.Gated.ResetInHandler do
  @moduledoc """
  `:detach` sets the field back to `false`: the next `:attach` monitors
  again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_info(:detach, state), do: {:noreply, %{state | attached: false}}
end

defmodule Argus.Test.Soundness.Gated.ResetFromMessage do
  @moduledoc """
  A call sets the field to whatever it is handed: `false` among them.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_call({:set, value}, _from, state), do: {:reply, :ok, %{state | attached: value}}
end

defmodule Argus.Test.Soundness.Gated.ResetThroughHelper do
  @moduledoc """
  `:detach` hands the state to a helper that clears the field.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_info(:detach, state), do: {:noreply, clear(state)}

  defp clear(state), do: %{state | attached: false}
end

defmodule Argus.Test.Soundness.Gated.ResetByTailCall do
  @moduledoc """
  `:detach` returns what a helper returns, and the helper's result
  clears the field.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_info(:detach, state), do: detach(state)

  defp detach(state), do: {:noreply, %{state | attached: false}}
end

defmodule Argus.Test.Soundness.Gated.ResetInCodeChange do
  @moduledoc """
  A code change starts the field over.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, %{state | attached: false}}
end

defmodule Argus.Test.Soundness.Gated.StateReplaced do
  @moduledoc """
  A call replaces the whole state with one it is handed.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_call({:restore, saved}, _from, _state), do: {:reply, :ok, saved}
end

defmodule Argus.Test.Soundness.Gated.ResetInTerminate do
  @moduledoc """
  terminate/2 clears the field on the way out: its return is dropped,
  and the process is gone.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def terminate(_reason, state), do: %{state | attached: false}
end

defmodule Argus.Test.Soundness.Gated.OtherFieldReset do
  @moduledoc """
  Another handler clears another field, and sets this one to the value
  that closes the gate.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false, count: 0}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_info(:clear, state), do: {:noreply, %{state | count: 0, attached: true}}
end

# ── The handler runs only as the process's loop runs it ──────────────

defmodule Argus.Test.Soundness.Gated.CalledWithFreshState do
  @moduledoc """
  Another handler runs the gated handler itself, with the field set back
  in the state it hands it: the site runs whatever the process holds.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_info(:reattach, state) do
    handle_cast(:attach, %{state | attached: false})
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Gated.CalledByClient do
  @moduledoc """
  A client function runs the handler in its caller's process, with a
  state of its own making.
  """
  use GenServer

  def attach_here, do: handle_cast(:attach, %{attached: false})

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end
end

defmodule Argus.Test.Soundness.Gated.HandedOn do
  @moduledoc """
  A handler hands its message and a state it makes to the gated one:
  a direct call, which the gate does not see.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end

  @impl true
  def handle_call(:force, _from, state) do
    {:noreply, next} = handle_cast(:attach, Map.put(state, :attached, false))
    {:reply, :ok, next}
  end
end

defmodule Argus.Test.Soundness.Gated.WrapperBehaviour do
  @moduledoc "A behaviour of the fixture's own, whose server returns other shapes."
  @callback handle_cast(term(), term()) :: term()
end

defmodule Argus.Test.Soundness.Gated.UnderWrapper do
  @moduledoc """
  A server under a behaviour the alias table does not know: its
  handlers' results are not read as GenServer's, and the gate is not
  trusted.
  """
  @behaviour Argus.Test.Soundness.Gated.WrapperBehaviour

  def init(_), do: {:ok, %{attached: false}}

  @impl true
  def handle_cast(:attach, %{attached: false} = state) do
    Process.monitor(Process.whereis(:gated_upstream))
    {:noreply, %{state | attached: true}}
  end
end

# ── A periodic loop a gated clause starts ────────────────────────────

defmodule Argus.Test.Soundness.Gated.LoopStartedOnce do
  @moduledoc """
  The loop is started from the clause `:registered` enters while
  `registered: false`, which the clause sets (blockster's
  BuxBoosterBetSettler): one loop.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{registered: false}}

  @impl true
  def handle_info(:registered, %{registered: false} = state) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, %{state | registered: true}}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Gated.LoopStartedAgain do
  @moduledoc """
  The same loop, and `:unregistered` sets the field back: the next
  `:registered` starts a second loop beside the running one.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{registered: false}}

  @impl true
  def handle_info(:registered, %{registered: false} = state) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, %{state | registered: true}}
  end

  def handle_info(:unregistered, state), do: {:noreply, %{state | registered: false}}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, state}
  end
end
