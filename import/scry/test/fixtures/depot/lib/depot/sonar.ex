defmodule Depot.Sonar do
  @moduledoc """
  Health monitor for the queue: listens on the `:health` channel and
  emits heartbeats through `Depot.Notifier`.

  The listener registration is made once, from `handle_continue/2`, and
  lives in the Notifier's state. A Notifier restart forgets it, and
  Sonar, not restarted with it, never listens again.
  """
  use GenServer

  alias Depot.Notifier

  @channel :health

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ping(GenServer.server()) :: :ok
  def ping(server) do
    GenServer.call(server, :ping)
  end

  @impl true
  def init(opts) do
    notifier = Keyword.get(opts, :notifier, Notifier)
    {:ok, %{notifier: notifier}, {:continue, :register}}
  end

  @impl true
  def handle_continue(:register, state) do
    # Registration lives in the Notifier's state. Lost on Notifier restart.
    Notifier.listen(state.notifier, @channel)
    {:noreply, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    # Succeeds even after the Notifier restarted and forgot every
    # listener — the heartbeat just vanishes.
    Notifier.notify(state.notifier, @channel, %{ping: true})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:depot_event, @channel, _payload}, state) do
    {:noreply, state}
  end
end
