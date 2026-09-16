defmodule Argus.Test.Fixtures.SupervisionShapes do
  @moduledoc false

  defmodule EventWorker do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(event), do: GenServer.start_link(__MODULE__, event)

    @impl true
    def init(event), do: {:ok, event, {:continue, :process}}

    @impl true
    def handle_continue(:process, event), do: {:stop, :normal, event}
  end

  defmodule PermanentConsumers do
    @moduledoc false
    # gen_stage#195: a permanent template restarts every finished child.
    use ConsumerSupervisor

    def start_link(opts), do: ConsumerSupervisor.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      children = [
        %{
          id: Argus.Test.Fixtures.SupervisionShapes.EventWorker,
          start: {Argus.Test.Fixtures.SupervisionShapes.EventWorker, :start_link, []},
          restart: :permanent
        }
      ]

      ConsumerSupervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule TemporaryConsumers do
    @moduledoc false
    use ConsumerSupervisor

    def start_link(opts), do: ConsumerSupervisor.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      children = [
        %{
          id: Argus.Test.Fixtures.SupervisionShapes.EventWorker,
          start: {Argus.Test.Fixtures.SupervisionShapes.EventWorker, :start_link, []},
          restart: :temporary
        }
      ]

      ConsumerSupervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule Conn do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule TempConn do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule DualManager do
    @moduledoc false
    # redix#334: monitors a permanent DynamicSupervisor child and restarts
    # it on :DOWN — as does the supervisor.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:connect, _from, state) do
      {:reply, :ok, connect(state)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
      {:noreply, connect(state)}
    end

    defp connect(state) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.SupervisionShapes.ConnSup,
          {Argus.Test.Fixtures.SupervisionShapes.Conn, []}
        )

      ref = Process.monitor(pid)
      Map.put(state, ref, pid)
    end
  end

  defmodule TemporaryManager do
    @moduledoc false
    # The same shape over a :temporary child: the manager is the only authority.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:connect, _from, state) do
      {:reply, :ok, connect(state)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
      {:noreply, connect(state)}
    end

    defp connect(state) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.SupervisionShapes.ConnSup,
          {Argus.Test.Fixtures.SupervisionShapes.TempConn, []}
        )

      ref = Process.monitor(pid)
      Map.put(state, ref, pid)
    end
  end

  defmodule StatemDualManager do
    @moduledoc false
    # redix#334 as written: a gen_statem whose :info clause funnels :DOWN into
    # a restart, with the start and the monitor in separate private helpers.
    @behaviour :gen_statem

    def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(data), do: {:ok, :connected, data}

    def connected({:call, from}, :connect, data) do
      {:keep_state, connect(data), [{:reply, from, :ok}]}
    end

    def connected(:info, {:DOWN, ref, :process, _pid, _reason}, data) do
      {:keep_state, handle_down(data, ref)}
    end

    defp handle_down(data, ref), do: connect(Map.delete(data, ref))

    defp connect(data) do
      {:ok, pid} = start_child(Map.get(data, :sup))
      monitor(data, pid)
    end

    defp start_child(sup) do
      DynamicSupervisor.start_child(sup, {Argus.Test.Fixtures.SupervisionShapes.Conn, []})
    end

    defp monitor(data, pid), do: Map.put(data, Process.monitor(pid), pid)
  end

  defmodule LateWarmup do
    @moduledoc false
    # phoenix#5981: the listener is accepting before the config it reads is written.

    def start_link(config) do
      {:ok, pid} =
        Supervisor.start_link([Argus.Test.Fixtures.SupervisionShapes.Conn],
          strategy: :one_for_one
        )

      warmup(config)
      {:ok, pid}
    end

    defp warmup(config), do: :persistent_term.put({__MODULE__, :config}, config)
  end

  defmodule EarlyWarmup do
    @moduledoc false

    def start_link(config) do
      :persistent_term.put({__MODULE__, :config}, config)
      Supervisor.start_link([Argus.Test.Fixtures.SupervisionShapes.Conn], strategy: :one_for_one)
    end
  end
end
