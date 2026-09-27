# Task.Supervisor.start_child returns an error only as {:error,
# :max_children}, under a cap: a discarded result hides a failure only
# where the supervisor the start names may have one (failure's
# "start_child result ignored", task_supervisor_cap).

defmodule Argus.Test.Fixtures.TaskCaps.App do
  @moduledoc false
  use Supervisor

  alias Argus.Test.Fixtures.TaskCaps

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    children = [
      {Task.Supervisor, name: TaskCaps.BoundedSup, max_children: 10},
      {Task.Supervisor, name: TaskCaps.OpenSup},
      {Task.Supervisor, name: TaskCaps.SizedSup, max_children: pool_size()},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: TaskCaps.Partitions},
      {PartitionSupervisor,
       child_spec: {Task.Supervisor, max_children: 2}, name: TaskCaps.CappedPartitions}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_size, do: Application.get_env(:task_caps, :pool_size, 4)
end

defmodule Argus.Test.Fixtures.TaskCaps.Starter do
  @moduledoc false
  alias Argus.Test.Fixtures.TaskCaps

  # A literal cap: at 10 tasks the start answers {:error, :max_children}.
  def to_bounded do
    Task.Supervisor.start_child(TaskCaps.BoundedSup, fn -> :work end)
    :ok
  end

  # No cap: the start cannot fail.
  def to_open do
    Task.Supervisor.start_child(TaskCaps.OpenSup, fn -> :work end)
    :ok
  end

  # A cap the extractor cannot read may be finite.
  def to_sized do
    Task.Supervisor.start_child(TaskCaps.SizedSup, fn -> :work end)
    :ok
  end

  # A partition of Task.Supervisors with no cap, and one with a cap.
  def to_partition do
    Task.Supervisor.start_child({:via, PartitionSupervisor, {TaskCaps.Partitions, self()}}, fn ->
      :work
    end)

    :ok
  end

  def to_capped_partition do
    Task.Supervisor.start_child(
      {:via, PartitionSupervisor, {TaskCaps.CappedPartitions, self()}},
      fn -> :work end
    )

    :ok
  end

  # A pid may be any Task.Supervisor the program starts, BoundedSup's too.
  def to_pid(sup) do
    Task.Supervisor.start_child(sup, fn -> :work end)
    :ok
  end
end

defmodule Argus.Test.Fixtures.TaskCaps.RuntimeServer do
  @moduledoc false
  # livebook's ErlDist.RuntimeServer: a Task.Supervisor started with no
  # options and kept in the state. The program starts no capped one, so
  # the start it names by pid cannot fail.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, %{task_supervisor: task_supervisor}}
  end

  @impl true
  def handle_cast({:run, fun}, state) do
    Task.Supervisor.start_child(state.task_supervisor, fun)
    {:noreply, state}
  end

  # A name the program does not start: taken as uncapped, the default.
  def to_elsewhere do
    Task.Supervisor.start_child(Argus.Test.Fixtures.TaskCaps.Elsewhere, fn -> :work end)
    :ok
  end
end
