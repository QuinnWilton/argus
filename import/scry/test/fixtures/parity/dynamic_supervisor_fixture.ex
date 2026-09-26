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

  # The supervisor is a runtime argument in a NON-supervisor module: it can't
  # be resolved to an atom, and there is no enclosing supervisor to anchor
  # to, so the parent stays the honest "dynamic" sentinel.
  def spawn_via_arg(sup) do
    DynamicSupervisor.start_child(sup, MyApp.Worker)
  end
end

defmodule Argus.Test.Fixtures.ViaApp.Registry do
  @moduledoc false
  # A registry via-tuple helper — the Oban.Registry.via/2 idiom. The last
  # module segment is "Registry", which is how the extractor recognizes it.
  def via(name, role), do: {:via, __MODULE__, {name, role}}
end

defmodule Argus.Test.Fixtures.ViaNursery do
  @moduledoc false
  use Supervisor

  alias Argus.Test.Fixtures.ViaApp.Registry

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: opts[:name])

  # A DynamicSupervisor and a GenServer, each registered under a via-tuple
  # whose role (Foreman / Midwife) is a compile-time literal but whose name
  # (conf.name) is runtime — forcing the whole child list to be built at
  # runtime, exactly like Oban.Nursery.
  @impl true
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)

    children = [
      {DynamicSupervisor, name: Registry.via(conf.name, Foreman)},
      {Argus.Test.Fixtures.ViaMidwife, conf: conf, name: Registry.via(conf.name, Midwife)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule Argus.Test.Fixtures.ViaMidwife do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.ViaApp.Registry

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  # start_child targets the Foreman DynamicSupervisor through a local helper
  # whose body is the via-tuple — the parent must resolve to the same via
  # name the Nursery registered it under.
  def start_queue(conf) do
    conf
    |> foreman()
    |> DynamicSupervisor.start_child({Argus.Test.Fixtures.ViaQueueSup, []})
  end

  defp foreman(conf), do: Registry.via(conf.name, Foreman)
end

defmodule Argus.Test.Fixtures.SelfAnchoringDynSup do
  @moduledoc false
  use DynamicSupervisor

  # The start_child helper receives the supervisor as a runtime argument
  # (pid or name unknown statically). Because the enclosing module is itself
  # a DynamicSupervisor, the child anchors to this module rather than
  # dropping to "dynamic".
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_worker(sup, arg) do
    DynamicSupervisor.start_child(sup, {Argus.Test.Fixtures.WorkerA, arg})
  end
end

defmodule Argus.Test.Fixtures.DynSupOwner do
  @moduledoc false
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
end
