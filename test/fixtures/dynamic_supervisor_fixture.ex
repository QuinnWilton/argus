defmodule Argus.Test.Fixtures.DynSupSpawner do
  @moduledoc false

  # Calls DynamicSupervisor.start_child with a static supervisor and child
  # module — the supervision extractor should emit dynamic_child for both.

  def spawn_worker_atom do
    DynamicSupervisor.start_child(MyApp.WorkerSupervisor, MyApp.Worker)
  end

  def spawn_worker_tuple(arg) do
    DynamicSupervisor.start_child(MyApp.WorkerSupervisor, {MyApp.Worker, arg})
  end
end

defmodule Argus.Test.Fixtures.DynSupOwner do
  @moduledoc false
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
end
