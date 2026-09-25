defmodule Argus.Test.Fixtures.InitAck do
  @moduledoc """
  Servers `:proc_lib.start_link/3` starts: what init/1 does before
  `:proc_lib.init_ack/1` holds its starter, and what it does after runs
  as the server, the start already returned. Each pair differs only in
  which side of the ack the wait is on. The startup window outlives the
  ack: a call to a later sibling after it still races that sibling's
  start.
  """

  defmodule RpcBefore do
    @moduledoc "An rpc before the ack: the start waits on the other node."
    use GenServer

    def start_link(node), do: :proc_lib.start_link(__MODULE__, :init, [node])

    @impl true
    def init(node) do
      config = :rpc.call(node, :application, :get_all_env, [:app])
      :proc_lib.init_ack({:ok, self()})
      :gen_server.enter_loop(__MODULE__, [], config)
    end
  end

  defmodule RpcAfter do
    @moduledoc "The same rpc after the ack: the server waits, not its start."
    use GenServer

    def start_link(node), do: :proc_lib.start_link(__MODULE__, :init, [node])

    @impl true
    def init(node) do
      :proc_lib.init_ack({:ok, self()})
      config = :rpc.call(node, :application, :get_all_env, [:app])
      :gen_server.enter_loop(__MODULE__, [], config)
    end
  end

  defmodule LockBefore do
    @moduledoc "A cluster-wide lock before the ack."
    use GenServer

    def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

    @impl true
    def init(opts) do
      :global.set_lock({__MODULE__, self()})
      :proc_lib.init_ack({:ok, self()})
      :gen_server.enter_loop(__MODULE__, [], opts)
    end
  end

  defmodule LockAfter do
    @moduledoc "The same lock after the ack."
    use GenServer

    def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

    @impl true
    def init(opts) do
      :proc_lib.init_ack({:ok, self()})
      :global.set_lock({__MODULE__, self()})
      :gen_server.enter_loop(__MODULE__, [], opts)
    end
  end

  defmodule CallsBefore do
    @moduledoc "Calls a sibling the supervisor starts later, before the ack: a deadlock."
    use GenServer

    alias Argus.Test.Fixtures.InitAck.Later

    def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])

    @impl true
    def init(:ok) do
      state = Later.get()
      :proc_lib.init_ack({:ok, self()})
      :gen_server.enter_loop(__MODULE__, [], state)
    end

    def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  defmodule CallsAfter do
    @moduledoc """
    The same call after the ack: the supervisor has moved on to start the
    sibling, so it is no deadlock, but the call races that start and
    exits :noproc when it wins (reported, as a handle_continue's is).
    """
    use GenServer

    alias Argus.Test.Fixtures.InitAck.Later

    def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [:ok])

    @impl true
    def init(:ok) do
      :proc_lib.init_ack({:ok, self()})
      state = Later.get()
      :gen_server.enter_loop(__MODULE__, [], state)
    end

    def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  defmodule Later do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def get, do: GenServer.call(__MODULE__, :get)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:get, _from, s), do: {:reply, s, s}
  end

  defmodule Sup do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.InitAck.{CallsAfter, CallsBefore, Later}

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: Supervisor.init([CallsBefore, CallsAfter, Later], strategy: :one_for_one)
  end
end
