defmodule Argus.Test.Fixtures.TagServerA do
  @moduledoc false
  # Half of a deadlock cycle whose every call targets a pid held in state:
  # only the message tags say who is called.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(peer), do: {:ok, %{peer: peer}}

  @impl true
  def handle_call({:tag_a_request, arg}, _from, state) do
    reply = GenServer.call(state.peer, {:tag_b_request, arg})
    {:reply, reply, state}
  end

  def handle_call(:shared_status, _from, state), do: {:reply, :a, state}
end

defmodule Argus.Test.Fixtures.TagServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(peer), do: {:ok, %{peer: peer}}

  @impl true
  def handle_call({:tag_b_request, arg}, _from, state) do
    reply = GenServer.call(state.peer, {:tag_a_request, arg})
    {:reply, reply, state}
  end

  def handle_call(:shared_status, _from, state), do: {:reply, :b, state}

  @impl true
  def handle_cast({:tag_b_note, _note}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TagProxy do
  @moduledoc false
  # A GenServer that is a client of TagServerB through a pid: its casts
  # carry B's tag, which its own handle_cast does not match. That is not a
  # message it sends itself.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def note(server, peer, note), do: GenServer.call(server, {:forward_note, peer, note})

  # Both tag servers answer :shared_status; a pid carrying it is ambiguous.
  def status(peer), do: GenServer.call(peer, :shared_status)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:forward_note, peer, note}, _from, state) do
    GenServer.cast(peer, {:tag_b_note, note})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TagGetServer do
  @moduledoc false
  # The only handler of `:get` in the fixture set — and `:get` names nothing.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(v), do: {:ok, v}

  @impl true
  def handle_call(:get, _from, v), do: {:reply, v, v}
end

defmodule Argus.Test.Fixtures.TagGenericClient do
  @moduledoc false
  def get(pid), do: GenServer.call(pid, :get)
end

defmodule Argus.Test.Fixtures.TagBumpServer do
  @moduledoc false
  # Handles {:bump, n} in handle_call — but so does a handle_info elsewhere,
  # so a pid sent {:bump, n} may be anything.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(v), do: {:ok, v}

  @impl true
  def handle_call({:bump, n}, _from, v), do: {:reply, v + n, v + n}
end

defmodule Argus.Test.Fixtures.TagBumpListener do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(v), do: {:ok, v}

  @impl true
  def handle_info({:bump, n}, v), do: {:noreply, v + n}
end

defmodule Argus.Test.Fixtures.TagBumpClient do
  @moduledoc false
  def bump(pid, n), do: GenServer.call(pid, {:bump, n})
end

defmodule Argus.Test.Fixtures.TagPool do
  @moduledoc false
  # Refers to TagServerA (starts it) and asks a pid for :shared_status,
  # which both tag servers answer: the reference breaks the tie.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def status(pool), do: GenServer.call(pool, :pool_status)

  @impl true
  def init(_) do
    {:ok, pid} = Argus.Test.Fixtures.TagServerA.start_link(self())
    {:ok, %{worker: pid}}
  end

  @impl true
  def handle_call(:pool_status, _from, state) do
    {:reply, GenServer.call(state.worker, :shared_status), state}
  end
end
