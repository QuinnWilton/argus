defmodule Argus.Test.Fixtures.GoodSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Argus.Test.Fixtures.WorkerA, []},
      {Argus.Test.Fixtures.WorkerB, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.PartitionSupervisorParent do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # PartitionSupervisor wraps the underlying child_spec across N partitions.
    # The supervision extractor should pierce the wrapper and emit
    # WorkerA as the supervised module.
    children = [
      {PartitionSupervisor, child_spec: Argus.Test.Fixtures.WorkerA, name: WorkerAPartition}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.BadOrderSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # WorkerB depends on WorkerA, but is started first — wrong order.
    children = [
      {Argus.Test.Fixtures.WorkerB, []},
      {Argus.Test.Fixtures.WorkerA, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.WorkerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}
end

defmodule Argus.Test.Fixtures.WorkerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def call_a(server), do: GenServer.call(server, :call_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:call_a, _from, state) do
    # This simulates calling WorkerA.
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.RuntimeCallerWorker do
  @moduledoc false
  use GenServer

  # Calls WorkerA only from handle_call (runtime), never from init.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def call_a(server), do: GenServer.call(server, :call_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:call_a, _from, state) do
    GenServer.call(Argus.Test.Fixtures.WorkerA, :ping)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.RuntimeCallSupervisor do
  @moduledoc false
  use Supervisor

  # RuntimeCallerWorker started before WorkerA — only calls it at runtime.
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Argus.Test.Fixtures.RuntimeCallerWorker, []},
      {Argus.Test.Fixtures.WorkerA, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.MapSpecSupervisor do
  @moduledoc false
  @behaviour :supervisor

  def start_link(arg) do
    :supervisor.start_link(__MODULE__, arg)
  end

  # Uses map child specs with a runtime variable in the start args to
  # force the compiler to emit put_map_assoc instead of literal folding.
  @impl true
  def init(arg) do
    children = [
      %{
        id: :worker_a,
        start: {Argus.Test.Fixtures.WorkerA, :start_link, [arg]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: :worker_b,
        start: {Argus.Test.Fixtures.WorkerB, :start_link, [arg]},
        restart: :transient,
        type: :worker
      }
    ]

    {:ok, {{:one_for_one, 5, 10}, children}}
  end
end

defmodule Argus.Test.Fixtures.MixedChildrenApp do
  @moduledoc false
  use Application

  # The stock Phoenix Application shape: one runtime element (options
  # computed at runtime) splits the children list into cons cells — a
  # bare module head, a runtime-built tuple, and a literal tail. The
  # extractor must recover the literal members from the put_list
  # operands, and the runtime tuple's module without it being loadable.
  @impl true
  def start(_type, _args) do
    children = [
      Argus.Test.Fixtures.WorkerA,
      {Argus.Test.Fixtures.RuntimeCallerWorker, timeout: System.get_env("ARGUS_T") || :none},
      {Argus.Test.Fixtures.WorkerB, name: :mixed_b},
      Argus.Test.Fixtures.GoodSupervisor
    ]

    opts = [strategy: :one_for_one, name: __MODULE__.Sup]
    Supervisor.start_link(children, opts)
  end
end

defmodule Argus.Test.Fixtures.NamedPoolSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # Two children of the same module (DynamicSupervisor) registered under
  # different names: they are two distinct supervisors, so dedup must keep
  # both, and each registered name must be recorded so a name-keyed
  # start_child can anchor to the right one.
  @impl true
  def init(_) do
    children = [
      {DynamicSupervisor, name: Argus.Test.Fixtures.PoolA, strategy: :one_for_one},
      {DynamicSupervisor, name: Argus.Test.Fixtures.PoolB, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ── wrong_start_order: process dependency vs pure-function reach ──────

defmodule Argus.Test.Fixtures.InitDepWorker do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  # A pure function — calling it does not require this process to be alive.
  def compute(x), do: x * 2

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Argus.Test.Fixtures.InitProcessCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Synchronously calls InitDepWorker's process during init — a genuine
  # start-order dependency: InitDepWorker must already be running.
  @impl true
  def init(opts) do
    :pong = GenServer.call(Argus.Test.Fixtures.InitDepWorker, :ping)
    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.InitPureCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Calls only a PURE function defined in InitDepWorker's module — no
  # dependency on InitDepWorker's process. Must NOT be a start-order
  # hazard (the Horde.RegistryImpl -> NodeListener.make_members shape).
  @impl true
  def init(opts) do
    _ = Argus.Test.Fixtures.InitDepWorker.compute(21)
    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.ProcessDepSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # Caller (position 0) starts before InitDepWorker (position 1) and
  # sync-calls it in init — wrong order.
  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.InitProcessCaller,
      Argus.Test.Fixtures.InitDepWorker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.PureDepSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  # Caller (position 0) starts before InitDepWorker (position 1) but only
  # calls a pure function in its module — not a start-order hazard.
  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.InitPureCaller,
      Argus.Test.Fixtures.InitDepWorker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
