defmodule Argus.Test.Fixtures.TimeoutChain.ServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get_data(server), do: GenServer.call(server, :get_data)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get_data, _from, state) do
    # Synchronous call to ServerB during handle_call — creates a chain.
    result = Argus.Test.Fixtures.TimeoutChain.ServerB.fetch(state.server_b)
    {:reply, result, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def fetch(server), do: GenServer.call(server, :fetch)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:fetch, _from, state) do
    # Synchronous call to ServerC — extends the chain to depth 2.
    val = Argus.Test.Fixtures.TimeoutChain.ServerC.lookup(state.server_c)
    {:reply, val, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerC do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def lookup(server), do: GenServer.call(server, :lookup)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:lookup, _from, state) do
    {:reply, state.value, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.BlockingCastServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def notify(server, msg), do: GenServer.cast(server, {:notify, msg})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:notify, _msg}, state) do
    # Synchronous call inside handle_cast — defeats the async purpose.
    _val = Argus.Test.Fixtures.TimeoutChain.ServerC.lookup(state.server_c)
    {:noreply, state}
  end
end

# A handle_cast whose waits are in its later clauses, each on a server of
# its own: every finding anchors at the call that waits, not at the first
# clause's head (handle_cast/2 is one function; its head is the :tick
# clause's line).
defmodule Argus.Test.Fixtures.TimeoutChain.LaterClauseCastServer do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.{ServerA, ServerB, ServerC}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:tick, state) do
    {:noreply, Map.update(state, :ticks, 1, &(&1 + 1))}
  end

  def handle_cast({:ping, from}, state) do
    send(from, :pong)
    {:noreply, state}
  end

  def handle_cast(:refresh, state) do
    value = refresh(state)
    {:noreply, Map.put(state, :value, value)}
  end

  def handle_cast(:fetch, state) do
    value = ServerB.fetch(state.server_b)
    {:noreply, Map.put(state, :fetched, value)}
  end

  # The wait is in a closure the clause hands to a helper: its site is the
  # call the closure is handed to.
  def handle_cast(:reload, state) do
    data = with_retry(fn -> ServerA.get_data(state.server_a) end)
    {:noreply, Map.put(state, :data, data)}
  end

  # Public so the compiler keeps the call a call (a private helper with
  # one caller may be inlined into the clause).
  def refresh(state), do: ServerC.lookup(state.server_c)

  def with_retry(fun) do
    fun.()
  rescue
    _ -> fun.()
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.BlockingCastStage do
  @moduledoc false
  # A GenStage answers calls and casts by GenServer's contract: its
  # handle_cast/2 blocks on a synchronous call as a GenServer's does.
  use GenStage

  def start_link(opts), do: GenStage.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:producer, state}

  @impl true
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl true
  def handle_cast({:notify, _msg}, state) do
    _val = Argus.Test.Fixtures.TimeoutChain.ServerC.lookup(state.server_c)
    {:noreply, [], state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerWithExplicitTimeout do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def request(server), do: GenServer.call(server, :request)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:request, _from, state) do
    # Calls ServerC with 10_000ms — when called by ServerA (default 5000ms),
    # the outer timeout cannot accommodate this downstream call.
    val = GenServer.call(state.server_c, :lookup, 10_000)
    {:reply, val, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerWithInfinityTimeout do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def request(server), do: GenServer.call(server, :request)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:request, _from, state) do
    # Calls ServerC with :infinity — can block the caller forever.
    val = GenServer.call(state.server_c, :lookup, :infinity)
    {:reply, val, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.DeepServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:fetch, _from, state) do
    # Downstream budget: the default 5000ms.
    val = GenServer.call(Argus.Test.Fixtures.TimeoutChain.ServerC, :lookup)
    {:reply, val, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.TightBudgetServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:go, _from, state) do
    # 1000ms budget for DeepServer, whose own downstream call waits up
    # to 5000ms — the outer timeout strictly cannot accommodate it.
    val = GenServer.call(Argus.Test.Fixtures.TimeoutChain.DeepServer, :fetch, 1000)
    {:reply, val, state}
  end
end

# ── Regression: pure-function reach must not manufacture a chain ──────
# Mirrors the commanded FP: a handle_call that reaches only a PURE
# function in another GenServer's module was chained to that module
# because the module has a GenServer.call *somewhere* else.

defmodule Argus.Test.Fixtures.TimeoutChain.ChainInner do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def sync(server), do: GenServer.call(server, :x)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:x, _from, state), do: {:reply, :ok, state}
end

defmodule Argus.Test.Fixtures.TimeoutChain.ChainMiddle do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # A PURE, exported function — no process interaction.
  def pure(k), do: k * 2

  @impl true
  def init(state), do: {:ok, state}

  # This module DOES have a sync call — but only here, to ChainInner.
  @impl true
  def handle_call(:go, _from, state) do
    _ = Argus.Test.Fixtures.TimeoutChain.ChainInner.sync(state.inner)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ChainOuter do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  # Reaches only ChainMiddle.pure/1 — a pure function. This must NOT be
  # read as a synchronous dependency on the ChainMiddle process, so no
  # ChainOuter -> ChainMiddle -> ChainInner timeout chain exists.
  @impl true
  def handle_call(:req, _from, state) do
    _ = Argus.Test.Fixtures.TimeoutChain.ChainMiddle.pure(21)
    {:reply, :ok, state}
  end
end

# Cast handlers that hand their message on to handle_info/2 unchanged, as
# zotonic's mod_acl_user_groups does (`handle_cast(rebuild, S) ->
# handle_info(rebuild, S)`): the call forwards the handler's first
# argument from a clause that took a literal, so handle_info/2 is entered
# at that literal's clauses only. In each, handle_info's :rebuild clause
# waits on nothing and its {:sync, _} clause calls ServerC.
#
# Quiet: the :rebuild clause forwards to the :rebuild clause.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:rebuild = msg, state), do: handle_info(msg, state)

  @impl true
  def handle_info(:rebuild, state), do: {:noreply, Map.put(state, :built, true)}

  def handle_info({:sync, server}, state) do
    _ = ServerC.lookup(server)
    {:noreply, state}
  end
end

# Reported: the {:sync, _} clause forwards to the clause that waits.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingSyncCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:sync, _} = msg, state), do: handle_info(msg, state)

  @impl true
  def handle_info(:rebuild, state), do: {:noreply, Map.put(state, :built, true)}

  def handle_info({:sync, server}, state) do
    _ = ServerC.lookup(server)
    {:noreply, state}
  end
end

# Reported: a clause that takes any message forwards it to every clause.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingAnyCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(msg, state), do: handle_info(msg, state)

  @impl true
  def handle_info(:rebuild, state), do: {:noreply, Map.put(state, :built, true)}

  def handle_info({:sync, server}, state) do
    _ = ServerC.lookup(server)
    {:noreply, state}
  end
end

# Adversarial probes for the forwarded-literal entry (FP hunt round 3):
# each forwards a literal it took, and still reaches a clause that waits.

# Reported: two handle_info/2 clauses take :rebuild, and the second waits.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingTwoClauseCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:rebuild = msg, state), do: handle_info(msg, state)

  @impl true
  def handle_info(:rebuild, %{mode: :idle} = state), do: {:noreply, state}

  def handle_info(:rebuild, state) do
    _ = ServerC.lookup(state.server)
    {:noreply, state}
  end
end

# Reported: one clause forwards its literal, another whatever it took.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingMixedCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:rebuild = msg, state), do: handle_info(msg, state)
  def handle_cast(other, state), do: handle_info(other, state)

  @impl true
  def handle_info(:rebuild, state), do: {:noreply, Map.put(state, :built, true)}

  def handle_info({:sync, server}, state) do
    _ = ServerC.lookup(server)
    {:noreply, state}
  end
end

# Reported: the clause that waits takes any atom by a guard, :rebuild too.
defmodule Argus.Test.Fixtures.TimeoutChain.ForwardingGuardCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.TimeoutChain.ServerC

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:rebuild = msg, state), do: handle_info(msg, state)

  @impl true
  def handle_info({:sync, _}, state), do: {:noreply, state}

  def handle_info(msg, state) when is_atom(msg) do
    _ = ServerC.lookup(state.server)
    {:noreply, state}
  end
end
