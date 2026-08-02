# Fixtures for the upcoming `deferred_startup_deadlock` analysis.
#
# Background: handle_continue/2 runs after init/1 returns, so a sync call
# from inside handle_continue does NOT block the parent supervisor — the
# supervisor's start_link has already returned by then. But there are
# three specific patterns where it IS a bug:
#
#   1. Mutual handle_continue cycle. A.handle_continue calls B sync,
#      B.handle_continue calls A sync. Both processes return from init,
#      the supervisor proceeds, but neither child ever processes any
#      mailbox messages.
#
#   2. handle_continue sync-calling a sibling started later under
#      :one_for_one. Sibling might not be ready yet; race window or
#      :noproc crash.
#
#   3. handle_continue sync-calling the parent supervisor while the
#      supervisor is still mid-start_link. The supervisor isn't reading
#      its mailbox yet, so the call hangs.
#
# These fixtures are the spec for the future analysis. The plan was to
# search ~/dev/beam_box/sample_projects/ for verified instances first;
# the search turned up zero, so the fixtures stand on their own.

# ── Pattern 1: mutual handle_continue cycle ──────────────────────────

defmodule Argus.Test.Fixtures.ContinueCycleServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    GenServer.call(Argus.Test.Fixtures.ContinueCycleServerB, :hello)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.ContinueCycleServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    GenServer.call(Argus.Test.Fixtures.ContinueCycleServerA, :hello)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.ContinueCycleSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.ContinueCycleServerA,
      Argus.Test.Fixtures.ContinueCycleServerB
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── Pattern 2: handle_continue calls later-started sibling ───────────

defmodule Argus.Test.Fixtures.ContinueLateTargetServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Argus.Test.Fixtures.ContinueLateCallerServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    GenServer.call(Argus.Test.Fixtures.ContinueLateTargetServer, :ping)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.ContinueLateSiblingSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The bad arrangement: caller starts FIRST, target starts LATER.
    children = [
      Argus.Test.Fixtures.ContinueLateCallerServer,
      Argus.Test.Fixtures.ContinueLateTargetServer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.SafeContinueOrderSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The safe arrangement: target starts FIRST, caller starts LATER.
    # The future analysis must NOT flag this case.
    children = [
      Argus.Test.Fixtures.ContinueLateTargetServer,
      Argus.Test.Fixtures.ContinueLateCallerServer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── Pattern 3: handle_continue calls back into parent supervisor ─────

defmodule Argus.Test.Fixtures.ContinueParentCallerServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    # The supervisor is still mid-start_link — this call hangs because
    # the supervisor isn't reading its mailbox yet.
    Supervisor.which_children(Argus.Test.Fixtures.ContinueParentSupervisor)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.ContinueParentSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Argus.Test.Fixtures.ContinueParentCallerServer]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── Safe counterpart: external target under a different supervisor ───
#
# The caller's continue sync-calls the target, but they're in disjoint
# supervision trees, so by the time the caller's continue runs the target
# has been alive for an unbounded time. The future analysis must NOT
# flag this case.

defmodule Argus.Test.Fixtures.SafeContinueExternalTarget do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Argus.Test.Fixtures.SafeContinueExternalCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    GenServer.call(Argus.Test.Fixtures.SafeContinueExternalTarget, :ping)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.SafeContinueExternalTargetSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Argus.Test.Fixtures.SafeContinueExternalTarget]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.SafeContinueExternalCallerSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Argus.Test.Fixtures.SafeContinueExternalCaller]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── Safe counterpart: continue uses cast, not call ───────────────────
#
# Cast is asynchronous — it can never deadlock. The future analysis must
# NOT flag this case even though the target is a later sibling.

defmodule Argus.Test.Fixtures.SafeContinueCastTarget do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast(:notify, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.SafeContinueCastCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    GenServer.cast(Argus.Test.Fixtures.SafeContinueCastTarget, :notify)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.SafeContinueCastSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.SafeContinueCastCaller,
      Argus.Test.Fixtures.SafeContinueCastTarget
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── Defensive variant: try/catch :exit converts deadlock to crash loop ──
#
# Modeled on electric/.../materializer.ex:108-135 — the only near-miss the
# corpus search turned up. The handle_continue sync-calls a later sibling
# but wraps the call in try/catch :exit. That converts the literal
# deadlock into a clean shutdown — but the supervisor will keep
# restarting the worker, so the system is stuck in a crash loop.
#
# The future analysis should classify this as a separate finding type
# (continue_crash_loop_risk) rather than the literal continue_to_later_sibling.

defmodule Argus.Test.Fixtures.DefensiveContinueTarget do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Argus.Test.Fixtures.DefensiveContinueCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :setup}}

  @impl true
  def handle_continue(:setup, state) do
    try do
      GenServer.call(Argus.Test.Fixtures.DefensiveContinueTarget, :ping, 5000)
      {:noreply, state}
    catch
      :exit, _reason -> {:stop, :shutdown, state}
    end
  end
end

defmodule Argus.Test.Fixtures.DefensiveContinueSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Bad arrangement: caller first, target later. The defensive try/catch
    # catches the literal deadlock but the supervisor restart loop is the
    # bug.
    children = [
      Argus.Test.Fixtures.DefensiveContinueCaller,
      Argus.Test.Fixtures.DefensiveContinueTarget
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.ContinueTagScope do
  @moduledoc """
  A handle_continue whose clause bodies compare atoms of their own.

  The tag arrives in {x,0}, but {x,0} is also the BEAM's first scratch
  register, so a body comparing `:ok` looks exactly like a clause head
  matching `:ok` unless the scan stops where the dispatch does.
  """
  use GenServer

  @impl GenServer
  def init(_), do: {:ok, %{}, {:continue, :setup}}

  @impl GenServer
  def handle_continue(:setup, state) do
    case check() do
      :ok -> {:noreply, state}
      :error -> {:stop, :failed, state}
    end
  end

  def handle_continue(:refresh, state) do
    if flag() == false, do: {:noreply, state}, else: {:noreply, state}
  end

  def check, do: :ok
  def flag, do: false
end
