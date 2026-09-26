defmodule Depot.Notifier do
  @moduledoc """
  In-process pub/sub for job lifecycle events. Listener registrations
  live only in this process's state, so a restart forgets them.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
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

  @impl true
  def init(_opts) do
    {:ok, %{listeners: %{}}}
  end

  @impl true
  def handle_call({:listen, channel, pid}, _from, state) do
    listeners = Map.update(state.listeners, channel, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | listeners: listeners}}
  end

  def handle_call({:notify, channel, payload}, _from, state) do
    for pid <- Map.get(state.listeners, channel, MapSet.new()) do
      send(pid, {:depot_event, channel, payload})
    end

    {:reply, :ok, state}
  end
end
