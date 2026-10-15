defmodule Depot.Queue do
  @moduledoc """
  A job queue with leased delivery. Completed jobs are handed to
  `Depot.Archive`; lifecycle events go through `Depot.Notifier`.
  """
  use GenServer

  alias Depot.{Archive, Notifier}

  @channel :jobs

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(GenServer.server(), term()) :: {:ok, pos_integer()}
  def enqueue(server, payload) do
    GenServer.call(server, {:enqueue, payload})
  end

  @spec claim(GenServer.server()) :: {:ok, map()} | :empty
  def claim(server) do
    GenServer.call(server, :claim)
  end

  @spec ack(GenServer.server(), pos_integer()) :: :ok | {:error, :unknown_job}
  def ack(server, job_id) do
    GenServer.call(server, {:ack, job_id})
  end

  @impl true
  def init(opts) do
    notifier = Keyword.get(opts, :notifier, Notifier)
    {:ok, %{jobs: %{}, next_id: 1, notifier: notifier}}
  end

  @impl true
  def handle_call({:enqueue, payload}, _from, state) do
    id = state.next_id
    job = %{id: id, payload: payload, status: :available}
    state = %{state | jobs: Map.put(state.jobs, id, job), next_id: id + 1}
    broadcast(state, %{event: :enqueued, id: id})
    {:reply, {:ok, id}, state}
  end

  def handle_call(:claim, _from, state) do
    case Enum.find(Map.values(state.jobs), &(&1.status == :available)) do
      nil ->
        {:reply, :empty, state}

      job ->
        leased = %{job | status: :leased}
        state = %{state | jobs: Map.put(state.jobs, job.id, leased)}
        broadcast(state, %{event: :claimed, id: job.id})
        {:reply, {:ok, leased}, state}
    end
  end

  def handle_call({:ack, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      %{status: :leased} = job ->
        done = %{job | status: :done}
        state = %{state | jobs: Map.put(state.jobs, job_id, done)}
        Archive.archive_async(done)
        broadcast(state, %{event: :done, id: job_id})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unknown_job}, state}
    end
  end

  defp broadcast(state, payload) do
    Notifier.notify(state.notifier, @channel, payload)
  end
end
