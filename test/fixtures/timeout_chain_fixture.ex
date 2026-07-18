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
