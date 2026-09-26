defmodule Argus.Test.Soundness.Census.Blocking do
  @moduledoc """
  The exclusion census's blocking holes (docs/design/exclusions.md,
  "Soundness surprises") and their adversarial neighbours. Asserted by
  test/soundness/blocking_test.exs.
  """
end

# ── A cycle of waits longer than two ─────────────────────────────────
#
# call_cycle knew only pairs, and the chain rule stops at a clause on a
# cycle: three servers each waiting on the next were reported by nothing.

defmodule Argus.Test.Soundness.Census.Blocking.Ring3A do
  @moduledoc """
  The census program: A answers :a by asking B, B answers :b by asking C,
  C answers :c by asking A, which is still waiting on B.
  """
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def a, do: GenServer.call(__MODULE__, :a)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:a, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.Ring3B.b(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring3B do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def b, do: GenServer.call(__MODULE__, :b)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:b, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.Ring3C.c(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring3C do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def c, do: GenServer.call(__MODULE__, :c)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:c, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.Ring3A.a(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring4Z do
  @moduledoc """
  A ring of four whose least module is not where the program starts:
  Z → Y (from a handle_info), Y → M through a helper, M → B, B → Z.
  """
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def z, do: GenServer.call(__MODULE__, :z)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_info(:tick, s) do
    _ = Argus.Test.Soundness.Census.Blocking.Ring4Y.y()
    {:noreply, s}
  end

  @impl true
  def handle_call(:z, _from, s), do: {:reply, :ok, s}
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring4Y do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def y, do: GenServer.call(__MODULE__, :y)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:y, _from, s), do: {:reply, ask_m(), s}

  defp ask_m, do: Argus.Test.Soundness.Census.Blocking.Ring4M.m()
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring4M do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def m, do: GenServer.call(__MODULE__, :m)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:m, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.Ring4B.b(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.Ring4B do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def b, do: GenServer.call(__MODULE__, :b)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:b, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.Ring4Z.z(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.TaskRingA do
  @moduledoc """
  A ring of three whose first wait is made in a task its handle_call
  awaits: the server is held all the same.
  """
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def a, do: GenServer.call(__MODULE__, :a)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:a, _from, s) do
    task = Task.async(fn -> Argus.Test.Soundness.Census.Blocking.TaskRingB.b() end)
    {:reply, Task.await(task), s}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.TaskRingB do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def b, do: GenServer.call(__MODULE__, :b)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:b, _from, s),
    do: {:reply, Argus.Test.Soundness.Census.Blocking.TaskRingC.c(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.TaskRingC do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def c, do: GenServer.call(__MODULE__, :c)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:c, _from, s),
    do: {:reply, Argus.Test.Soundness.Census.Blocking.TaskRingA.a(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.LineA do
  @moduledoc "Quiet: A → B → C with nothing back into A, a chain and no cycle."
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def a, do: GenServer.call(__MODULE__, :a)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:a, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.LineB.b(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.LineB do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def b, do: GenServer.call(__MODULE__, :b)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:b, _from, s), do: {:reply, Argus.Test.Soundness.Census.Blocking.LineC.c(), s}
end

defmodule Argus.Test.Soundness.Census.Blocking.LineC do
  @moduledoc """
  Quiet: its client function calls A, but only its callers run it — C's
  own process waits on nobody.
  """
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def c, do: GenServer.call(__MODULE__, :c)
  def via_a, do: Argus.Test.Soundness.Census.Blocking.LineA.a()

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:c, _from, s), do: {:reply, :ok, s}
end

# ── A catch for the peer's bare :shutdown, not its shutdown with a reason ──

defmodule Argus.Test.Soundness.Census.Blocking.NavParent do
  @moduledoc """
  A parent view: navigating away stops it with `{:shutdown, :redirect}`.
  A child's call queued behind :navigate exits `{{:shutdown, :redirect},
  {GenServer, :call, _}}`.
  """
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call({:child_mount, _child}, _from, s), do: {:reply, {:ok, s}, s}

  @impl true
  def handle_info(:navigate, s), do: {:stop, {:shutdown, :redirect}, s}
end

defmodule Argus.Test.Soundness.Census.Blocking.NoprocAndShutdown do
  @moduledoc """
  The census program (phoenix_live_view#4359's child): a clause for
  `{:shutdown, _}` beside `:noproc` takes the parent's bare :shutdown
  stop, not its `{:shutdown, :redirect}` one, which crashes the child.
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:shutdown, _} -> {:error, :shutdown}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.NoprocAndNormal do
  @moduledoc """
  Quiet, a known limit: a clause for `{:normal, _}` beside `:noproc`
  takes the peer's normal stop, one of the two it makes itself. Which
  stops this peer makes is not resolved at the call: NavParent's
  `{:shutdown, :redirect}` crashes it all the same.
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :parent_stopped}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.NoprocAndBareShutdown do
  @moduledoc """
  A clause for the bare `:shutdown` exit beside `{:noproc, _}`: neither
  takes a call's exit of a peer that stopped itself.
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, :shutdown -> {:error, :shutdown}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.EveryStopShape do
  @moduledoc """
  Quiet: hackney_conn's safe_call shape, with `{{:shutdown, _}, _}` too:
  every stop a peer makes itself is taken.
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :closed}
    :exit, {:normal, _} -> {:error, :closed}
    :exit, {:shutdown, _} -> {:error, :closed}
    :exit, {{:shutdown, _}, _} -> {:error, :closed}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.NoprocAndInnerNoproc do
  @moduledoc """
  A clause for the shutdown-with-reason shape of another reason
  (`{{:noproc, _}, _}`): still not the parent's `{:shutdown, :redirect}`.
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {{:noproc, _}, _} -> {:error, :nested}
  end
end

defmodule Argus.Test.Soundness.Census.Blocking.NoprocAndInnerShutdown do
  @moduledoc """
  Quiet: b100e10's fix, a clause for `{{:shutdown, _}, _}` (the parent's
  redirect kinds, as the fix names them).
  """
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    GenServer.call(parent, {:child_mount, self()})
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {{:shutdown, {kind, _}}, _} when kind in [:redirect, :live_redirect] -> {:error, kind}
  end
end
