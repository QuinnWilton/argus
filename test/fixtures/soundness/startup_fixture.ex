defmodule Argus.Test.Soundness.Startup do
  @moduledoc """
  Real startup bugs a suppression once silenced, and the adversarial
  shapes beside each: `test/soundness/startup_test.exs` asserts the
  finding each must keep.
  """

  # ── A cast a task init/1 starts (review 2, item 11) ──────────────────
  # 87209008 made a cast a spawned process makes that process's own, so a
  # task init/1 starts that casts to a later sibling went quiet. The task
  # runs at once, while the supervisor starts the siblings after it.

  defmodule TaskCast do
    @moduledoc false

    defmodule Announcer do
      @moduledoc """
      init/1 hands its announcement to a task and returns. The task runs
      at once, while the supervisor is still starting the siblings after
      this one: its cast goes to a name Registry is not yet registered
      under, and is dropped on nearly every boot.
      """
      use GenServer
      alias Argus.Test.Soundness.Startup.TaskCast.Registry

      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok) do
        {:ok, _} = Task.start_link(fn -> Registry.announce(:announcer) end)
        {:ok, %{}}
      end
    end

    defmodule Registry do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def announce(who), do: GenServer.cast(__MODULE__, {:announce, who})

      @impl true
      def init(:ok), do: {:ok, MapSet.new()}

      @impl true
      def handle_cast({:announce, who}, s), do: {:noreply, MapSet.put(s, who)}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.TaskCast.{Announcer, Registry}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Announcer, Registry], strategy: :one_for_one)
    end
  end

  defmodule AwaitedTaskCast do
    @moduledoc false

    defmodule Announcer do
      @moduledoc """
      init/1 runs its announcement in a task and waits for it: the cast is
      made before init/1 returns, while Registry cannot be alive yet, and
      is dropped on every boot.
      """
      use GenServer
      alias Argus.Test.Soundness.Startup.AwaitedTaskCast.Registry

      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok) do
        Task.async(fn -> Registry.announce(:announcer) end) |> Task.await()
        {:ok, %{}}
      end
    end

    defmodule Registry do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def announce(who), do: GenServer.cast(__MODULE__, {:announce, who})

      @impl true
      def init(:ok), do: {:ok, MapSet.new()}

      @impl true
      def handle_cast({:announce, who}, s), do: {:noreply, MapSet.put(s, who)}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AwaitedTaskCast.{Announcer, Registry}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Announcer, Registry], strategy: :one_for_one)
    end
  end

  defmodule SpawnCast do
    @moduledoc false

    defmodule Announcer do
      @moduledoc "A bare spawn from a helper init/1 calls; the spawned fun casts at once."
      use GenServer
      alias Argus.Test.Soundness.Startup.SpawnCast.Registry

      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok) do
        announce_later()
        {:ok, %{}}
      end

      defp announce_later, do: spawn(fn -> Registry.announce(:announcer) end)
    end

    defmodule Registry do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def announce(who), do: GenServer.cast(__MODULE__, {:announce, who})

      @impl true
      def init(:ok), do: {:ok, MapSet.new()}

      @impl true
      def handle_cast({:announce, who}, s), do: {:noreply, MapSet.put(s, who)}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.SpawnCast.{Announcer, Registry}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Announcer, Registry], strategy: :one_for_one)
    end
  end

  # ── The ack ends the start's hold, not the startup window ───────────
  # (review 2, item 12: b918a331 cut every walk of init/1 at its
  # :proc_lib.init_ack, the startup-window questions too.)

  defmodule AckEarly do
    @moduledoc false

    defmodule Cache do
      @moduledoc """
      Acks its start at once, and then loads its state from Config — a
      sibling the supervisor starts next. The call reaches a name nobody
      holds yet and exits :noproc: Cache crashes, and the tree boots on a
      restart. The ack changed nothing about the ordering bug.
      """
      use GenServer
      alias Argus.Test.Soundness.Startup.AckEarly.Config

      def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

      @impl true
      def init(:ok) do
        :proc_lib.init_ack({:ok, self()})
        state = Config.all()
        :gen_server.enter_loop(__MODULE__, [], state)
      end
    end

    defmodule Config do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def all, do: GenServer.call(__MODULE__, :all)

      @impl true
      def init(:ok), do: {:ok, %{}}

      @impl true
      def handle_call(:all, _from, s), do: {:reply, s, s}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AckEarly.{Cache, Config}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Cache, Config], strategy: :one_for_one)
    end
  end

  defmodule AckHelpers do
    @moduledoc false

    defmodule Cache do
      @moduledoc "The post-ack call and cast to later siblings, in a helper."
      use GenServer
      alias Argus.Test.Soundness.Startup.AckHelpers.{Config, Events}

      def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

      @impl true
      def init(:ok) do
        :proc_lib.init_ack({:ok, self()})
        state = load()
        :gen_server.enter_loop(__MODULE__, [], state)
      end

      defp load do
        Events.started(:cache)
        Config.all()
      end
    end

    defmodule Config do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def all, do: GenServer.call(__MODULE__, :all)

      @impl true
      def init(:ok), do: {:ok, %{}}

      @impl true
      def handle_call(:all, _from, s), do: {:reply, s, s}
    end

    defmodule Events do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
      def started(who), do: GenServer.cast(__MODULE__, {:started, who})

      @impl true
      def init(:ok), do: {:ok, []}

      @impl true
      def handle_cast({:started, who}, s), do: {:noreply, [who | s]}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AckHelpers.{Cache, Config, Events}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Cache, Config, Events], strategy: :one_for_one)
    end
  end

  defmodule AckAsksSup do
    @moduledoc false

    defmodule Worker do
      @moduledoc """
      Acks its start and then asks its supervisor for its siblings. The
      supervisor is still starting Later and answers no call until every
      child is up; Later's init/1 calls Worker, which is stuck in
      which_children: the boot deadlocks until a timeout crashes it.
      """
      use GenServer
      alias Argus.Test.Soundness.Startup.AckAsksSup.Sup

      def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
      def ping, do: GenServer.call(__MODULE__, :ping)

      @impl true
      def init(:ok) do
        Process.register(self(), __MODULE__)
        :proc_lib.init_ack({:ok, self()})
        siblings = Supervisor.which_children(Sup)
        :gen_server.enter_loop(__MODULE__, [], %{siblings: siblings})
      end

      @impl true
      def handle_call(:ping, _from, s), do: {:reply, :pong, s}
    end

    defmodule Later do
      @moduledoc false
      use GenServer
      alias Argus.Test.Soundness.Startup.AckAsksSup.Worker
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok) do
        :pong = Worker.ping()
        {:ok, nil}
      end
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AckAsksSup.{Later, Worker}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Worker, Later], strategy: :one_for_one)
    end
  end

  defmodule AckSupHelper do
    @moduledoc false

    defmodule Worker do
      @moduledoc "Acks, then asks its parent for its children from a helper."
      use GenServer
      alias Argus.Test.Soundness.Startup.AckSupHelper.Sup

      def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

      @impl true
      def init(:ok) do
        :proc_lib.init_ack({:ok, self()})
        :gen_server.enter_loop(__MODULE__, [], siblings())
      end

      defp siblings, do: Supervisor.which_children(Sup)
    end

    defmodule Later do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok), do: {:ok, nil}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AckSupHelper.{Later, Worker}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Worker, Later], strategy: :one_for_one)
    end
  end

  defmodule AckLastAsksSup do
    @moduledoc false

    defmodule Earlier do
      @moduledoc false
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl true
      def init(:ok), do: {:ok, nil}
    end

    defmodule Worker do
      @moduledoc "Quiet: the last child asks its parent after its ack; nothing later waits on it."
      use GenServer
      alias Argus.Test.Soundness.Startup.AckLastAsksSup.Sup

      def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])
      def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

      @impl true
      def init(:ok) do
        :proc_lib.init_ack({:ok, self()})
        :gen_server.enter_loop(__MODULE__, [], Supervisor.which_children(Sup))
      end
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.AckLastAsksSup.{Earlier, Worker}
      def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

      @impl true
      def init(nil), do: Supervisor.init([Earlier, Worker], strategy: :one_for_one)
    end
  end

  defmodule AckConnect do
    @moduledoc """
    A client that acks its start early and then connects, with no way to
    try again: when the broker is down, the match crashes the process a
    moment after its start returned, the supervisor restarts it at once,
    and after max_restarts the tree goes down (tortoise#46's shape).
    """
    use GenServer

    def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @impl true
    def init(opts) do
      :proc_lib.init_ack({:ok, self()})
      {:ok, sock} = :gen_tcp.connect(~c"broker.local", 1883, [:binary, active: true])
      :gen_server.enter_loop(__MODULE__, [], %{sock: sock, opts: opts})
    end

    @impl true
    def handle_info({:tcp, _sock, _data}, s), do: {:noreply, s}
    def handle_info({:tcp_closed, _sock}, s), do: {:stop, :normal, s}
  end

  defmodule AckConnectHelper do
    @moduledoc "Acks, then connects from a helper with no retry."
    use GenServer

    def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @impl true
    def init(opts) do
      :proc_lib.init_ack({:ok, self()})
      :gen_server.enter_loop(__MODULE__, [], connect(opts))
    end

    defp connect(opts) do
      {:ok, sock} = :gen_tcp.connect(~c"broker.local", 1883, [:binary, active: true])
      %{sock: sock, opts: opts}
    end

    @impl true
    def handle_info({:tcp, _sock, _data}, s), do: {:noreply, s}
  end

  # ── A later child the extractor cannot read (review 2, item 20) ──────
  # 660c6296 quieted a worker that is its supervisor's last child; a
  # child written with Supervisor.child_spec/2 was filed before it, and a
  # list appended from config was not seen at all, so the worker looked
  # last.

  defmodule ContSpec do
    @moduledoc false

    defmodule Worker do
      @moduledoc "handle_continue calls its own supervisor while it starts the child after it."
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, %{}, {:continue, :peers}}

      @impl true
      def handle_continue(:peers, s) do
        kids = GenServer.call(Argus.Test.Soundness.Startup.ContSpec.Sup, :which_children)
        {:noreply, Map.put(s, :kids, kids)}
      end
    end

    defmodule Later do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(o), do: {:ok, o}
    end

    defmodule Sup do
      @moduledoc "The later child is written with Supervisor.child_spec/2 (an id override)."
      use Supervisor
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_) do
        children = [
          Argus.Test.Soundness.Startup.ContSpec.Worker,
          Supervisor.child_spec({Argus.Test.Soundness.Startup.ContSpec.Later, []}, id: :later)
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end
  end

  defmodule ContConfig do
    @moduledoc false

    defmodule Worker do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, %{}, {:continue, :peers}}

      @impl true
      def handle_continue(:peers, s) do
        kids = GenServer.call(Argus.Test.Soundness.Startup.ContConfig.Sup, :which_children)
        {:noreply, Map.put(s, :kids, kids)}
      end
    end

    defmodule Sup do
      @moduledoc "The children after the worker come from the application's config."
      use Supervisor
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_) do
        children = [
          Argus.Test.Soundness.Startup.ContConfig.Worker
          | Application.get_env(:argus, :soundness_workers, [])
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end
  end

  defmodule ContHelper do
    @moduledoc false

    defmodule Worker do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, %{}, {:continue, :peers}}

      @impl true
      def handle_continue(:peers, s),
        do:
          {:noreply,
           Map.put(
             s,
             :kids,
             Supervisor.which_children(Argus.Test.Soundness.Startup.ContHelper.Sup)
           )}
    end

    defmodule Sup do
      @moduledoc "The list comes from a local helper that appends config."
      use Supervisor
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: Supervisor.init(children(), strategy: :one_for_one)

      defp children,
        do: [
          Argus.Test.Soundness.Startup.ContHelper.Worker
          | Application.get_env(:argus, :soundness_extra, [])
        ]
    end
  end

  defmodule ContMapped do
    @moduledoc false

    defmodule Worker do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, %{}, {:continue, :peers}}

      @impl true
      def handle_continue(:peers, s),
        do:
          {:noreply,
           Map.put(s, :n, Supervisor.count_children(Argus.Test.Soundness.Startup.ContMapped.Sup))}
    end

    defmodule Shard do
      @moduledoc false
      use GenServer
      def start_link(i), do: GenServer.start_link(__MODULE__, i)

      @impl true
      def init(i), do: {:ok, i}
    end

    defmodule Sup do
      @moduledoc "The later children are an Enum.map of specs."
      use Supervisor
      alias Argus.Test.Soundness.Startup.ContMapped.{Shard, Worker}
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(n) do
        shards = Enum.map(1..n, &Supervisor.child_spec({Shard, &1}, id: {:shard, &1}))
        Supervisor.init([Worker | shards], strategy: :one_for_one)
      end
    end
  end

  defmodule SpecOrder do
    @moduledoc false

    defmodule Worker do
      @moduledoc """
      init/1 calls a sibling written with Supervisor.child_spec/2 after it:
      the child list filed that sibling first, and the deadlock went unread.
      """
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, Argus.Test.Soundness.Startup.SpecOrder.Later.get()}
    end

    defmodule Later do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
      def get, do: GenServer.call(__MODULE__, :get)

      @impl true
      def init(o), do: {:ok, o}

      @impl true
      def handle_call(:get, _from, s), do: {:reply, s, s}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.SpecOrder.{Later, Worker}
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_),
        do:
          Supervisor.init([Worker, Supervisor.child_spec({Later, []}, id: :later)],
            strategy: :one_for_one
          )
    end
  end

  defmodule ContLast do
    @moduledoc false

    defmodule Worker do
      @moduledoc "Quiet: the worker is a closed list's last child."
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_), do: {:ok, %{}, {:continue, :peers}}

      @impl true
      def handle_continue(:peers, s),
        do:
          {:noreply,
           Map.put(s, :kids, Supervisor.which_children(Argus.Test.Soundness.Startup.ContLast.Sup))}
    end

    defmodule Earlier do
      @moduledoc false
      use GenServer
      def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(o), do: {:ok, o}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor
      alias Argus.Test.Soundness.Startup.ContLast.{Earlier, Worker}
      def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

      @impl true
      def init(_),
        do:
          Supervisor.init([Supervisor.child_spec({Earlier, []}, id: :e), Worker],
            strategy: :one_for_one
          )
    end
  end
end
