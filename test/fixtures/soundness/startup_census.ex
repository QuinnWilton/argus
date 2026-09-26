defmodule Argus.Test.Soundness.Census.Startup do
  @moduledoc """
  The exclusion census's startup holes (docs/design/exclusions.md,
  "Soundness surprises") and their adversarial neighbours: two trees were
  taken as running for each other by being two, and a task init/1 awaits
  was not its wait. Asserted by test/soundness/startup_test.exs.
  """
end

# ── A process the start function starts after the tree ──────────────

defmodule Argus.Test.Soundness.Census.Startup.Config do
  @moduledoc "A config server the applications below start by hand."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:get, key}, _from, cfg), do: {:reply, Map.get(cfg, key), cfg}
end

defmodule Argus.Test.Soundness.Census.Startup.Cache do
  @moduledoc "Reads its size from Config while it starts."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    size = Argus.Test.Soundness.Census.Startup.Config.get(:cache_size)
    {:ok, %{size: size, entries: %{}}}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.App do
  @moduledoc """
  The census program: the tree holding Cache starts first, Config after
  it returns. Cache's init/1 calls Config, which is not registered yet:
  the call exits :noproc, the tree fails and the application with it.
  """
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, sup} =
      Supervisor.start_link([Argus.Test.Soundness.Census.Startup.Cache],
        strategy: :one_for_one,
        name: Argus.Test.Soundness.Census.Startup.Sup
      )

    {:ok, _} = Argus.Test.Soundness.Census.Startup.Config.start_link(cache_size: 100)
    {:ok, sup}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.SizedCache do
  @moduledoc "Reads Config on some paths only."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    size =
      if Keyword.get(opts, :sized, true),
        do: Argus.Test.Soundness.Census.Startup.Config.get(:cache_size),
        else: 10

    {:ok, %{size: size}}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.SizedApp do
  @moduledoc "The same order, with the conditional reader."
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, sup} =
      Supervisor.start_link([Argus.Test.Soundness.Census.Startup.SizedCache],
        strategy: :one_for_one
      )

    {:ok, _} = Argus.Test.Soundness.Census.Startup.Config.start_link([])
    {:ok, sup}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.EarlyConfigCache do
  @moduledoc "Reads Config while it starts; the application below starts Config first."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts),
    do: {:ok, %{size: Argus.Test.Soundness.Census.Startup.Config.get(:cache_size)}}
end

defmodule Argus.Test.Soundness.Census.Startup.EarlyApp do
  @moduledoc "Quiet: Config starts before the tree that reads it."
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, _} = Argus.Test.Soundness.Census.Startup.Config.start_link(cache_size: 100)

    Supervisor.start_link([Argus.Test.Soundness.Census.Startup.EarlyConfigCache],
      strategy: :one_for_one
    )
  end
end

# ── A later sibling a task init/1 awaits calls ────────────────────────

defmodule Argus.Test.Soundness.Census.Startup.Settings do
  @moduledoc "A later sibling the caches below read at start."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: {:ok, %{ttl: 60_000}}

  @impl true
  def handle_call(:cfg, _from, s), do: {:reply, s, s}
end

defmodule Argus.Test.Soundness.Census.Startup.TaskCache do
  @moduledoc """
  The census program: init/1 fetches its configuration through a task it
  awaits, from Settings, a later sibling. The supervisor cannot start
  Settings until init/1 returns: the start deadlocks until the await's
  timeout crashes it.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    cfg =
      Task.async(fn -> GenServer.call(Argus.Test.Soundness.Census.Startup.Settings, :cfg) end)
      |> Task.await()

    {:ok, %{cfg: cfg, entries: %{}}}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.HelperTaskCache do
  @moduledoc "The same wait in a helper init/1 calls."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: {:ok, %{cfg: fetch()}}

  defp fetch do
    task =
      Task.async(fn -> GenServer.call(Argus.Test.Soundness.Census.Startup.Settings, :cfg) end)

    Task.await(task, 1_000)
  end
end

defmodule Argus.Test.Soundness.Census.Startup.FireAndForgetCache do
  @moduledoc """
  A task init/1 starts and does not await: init/1 holds nothing, and the
  call is the startup window's warning, not the deadlock.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(arg) do
    Task.start(fn -> GenServer.call(Argus.Test.Soundness.Census.Startup.Settings, :cfg) end)
    {:ok, arg}
  end
end

defmodule Argus.Test.Soundness.Census.Startup.TaskSup do
  @moduledoc "The caches before Settings, one_for_one."
  use Supervisor

  alias Argus.Test.Soundness.Census.Startup, as: S

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    Supervisor.init([S.TaskCache, S.HelperTaskCache, S.FireAndForgetCache, S.Settings],
      strategy: :one_for_one
    )
  end
end
