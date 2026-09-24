defmodule Argus.Test.Fixtures.CycleServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_b(server), do: GenServer.call(server, :ask_b)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_b, _from, state) do
    # Sync-calls CycleServerB — creates half of a deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerB, :ping)
    {:reply, result, state}
  end
end

defmodule Argus.Test.Fixtures.CycleServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_a(server), do: GenServer.call(server, :ask_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_a, _from, state) do
    # Sync-calls CycleServerA — completes the deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerA, :ping)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end
end

defmodule Argus.Test.Fixtures.CallCycle do
  @moduledoc """
  Shapes that look like a synchronous call cycle between two modules, and
  the ones beside them that are: two modules call each other only when
  their processes do.
  """

  # ── A buffer module and its thin wrappers (Plausible's write buffers) ──

  defmodule WriteBuffer do
    @moduledoc "One server module; each wrapper below starts an instance under its own name."
    use GenServer

    def child_spec(opts), do: %{id: opts[:name], start: {__MODULE__, :start_link, [opts]}}

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def insert(server, row), do: GenServer.cast(server, {:insert, row})
    def flush(server), do: GenServer.call(server, :flush, :infinity)

    @impl true
    def init(opts), do: {:ok, %{name: opts[:name], rows: []}}

    @impl true
    def handle_cast({:insert, row}, state), do: {:noreply, %{state | rows: [row | state.rows]}}

    @impl true
    def handle_call(:flush, _from, state), do: {:reply, :ok, %{state | rows: []}}
  end

  defmodule EventBuffer do
    @moduledoc "Names a WriteBuffer after itself; runs no process of its own."
    alias Argus.Test.Fixtures.CallCycle.WriteBuffer

    def child_spec(opts), do: WriteBuffer.child_spec(Keyword.put(opts, :name, __MODULE__))
    def insert(row), do: WriteBuffer.insert(__MODULE__, row)
    def flush, do: WriteBuffer.flush(__MODULE__)
  end

  defmodule SessionBuffer do
    @moduledoc false
    alias Argus.Test.Fixtures.CallCycle.WriteBuffer

    def child_spec(opts), do: WriteBuffer.child_spec(Keyword.put(opts, :name, __MODULE__))
    def insert(row), do: WriteBuffer.insert(__MODULE__, row)
    def flush, do: WriteBuffer.flush(__MODULE__)
  end

  defmodule Buffers do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.CallCycle.{EventBuffer, SessionBuffer}

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts), do: Supervisor.init([EventBuffer, SessionBuffer], strategy: :one_for_one)
  end
end
