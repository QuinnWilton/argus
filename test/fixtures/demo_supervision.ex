defmodule Argus.Test.Fixtures.DemoNotifier do
  @moduledoc false
  use GenServer

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec listen(GenServer.server(), atom()) :: :ok
  def listen(server, channel) do
    GenServer.call(server, {:listen, channel, self()})
  end

  @spec notify(GenServer.server(), atom(), map()) :: :ok
  def notify(server, channel, payload) do
    GenServer.call(server, {:notify, channel, payload})
  end

  @spec listeners(GenServer.server(), atom()) :: MapSet.t(pid())
  def listeners(server, channel) do
    GenServer.call(server, {:listeners, channel})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{listeners: %{}}}
  end

  @impl true
  def handle_call({:listen, channel, pid}, _from, state) do
    listeners =
      Map.update(state.listeners, channel, MapSet.new([pid]), &MapSet.put(&1, pid))

    {:reply, :ok, %{state | listeners: listeners}}
  end

  def handle_call({:notify, channel, payload}, _from, state) do
    pids = Map.get(state.listeners, channel, MapSet.new())

    for pid <- pids do
      send(pid, {:notification, channel, payload})
    end

    {:reply, :ok, state}
  end

  def handle_call({:listeners, channel}, _from, state) do
    {:reply, Map.get(state.listeners, channel, MapSet.new()), state}
  end
end

defmodule Argus.Test.Fixtures.DemoSonar do
  @moduledoc false
  use GenServer

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ping(GenServer.server()) :: :ok
  def ping(server) do
    GenServer.call(server, :ping)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    notifier = Keyword.fetch!(opts, :notifier)
    {:ok, %{notifier: notifier}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    # Mirrors Oban.Sonar line 49: registers self as listener on the :sonar channel.
    # This registration lives in Notifier's state — if Notifier crashes
    # and restarts, this registration is lost.
    Argus.Test.Fixtures.DemoNotifier.listen(state.notifier, :sonar)
    {:noreply, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    # Mirrors Oban.Sonar line 50/72: broadcasts a ping via Notifier.
    # The call itself succeeds even after Notifier restarts, but nobody
    # receives the notification because the listener list is empty.
    Argus.Test.Fixtures.DemoNotifier.notify(state.notifier, :sonar, %{ping: true})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:notification, :sonar, _payload}, state) do
    {:noreply, state}
  end
end
