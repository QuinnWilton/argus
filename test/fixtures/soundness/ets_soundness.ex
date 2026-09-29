defmodule S2c.Ets.Job do
  @moduledoc false
  @callback perform(term()) :: term()
end

defmodule S2c.Ets.Plugish do
  @moduledoc false
  @callback call(term(), term()) :: term()
end

defmodule Probe.R2.G5.WarmRatesJob do
  # A background job (Oban runs perform/1 in a short-lived task) warms a
  # named cache table: the table's owner is the job's process, and the
  # table is deleted the moment perform/1 returns. Every later read by
  # Rates.lookup/1 raises ArgumentError.
  @behaviour S2c.Ets.Job

  def perform(%{args: %{"rates" => rates}}) do
    :ets.new(:probe_g5_rates, [:named_table, :public, :set, read_concurrency: true])
    for {k, v} <- rates, do: :ets.insert(:probe_g5_rates, {k, v})
    :ok
  end
end

defmodule Probe.R2.G5.Rates do
  def lookup(k), do: :ets.lookup(:probe_g5_rates, k)
end

defmodule Probe.R2.G7.KeeperServer do
  # init/1 spawns a bare keeper process that makes the shared table and
  # sleeps: the keeper owns it, with no heir, under no supervisor. When
  # the keeper dies (killed, or an exit signal) the table goes with it,
  # and every reader raises badarg.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(k), do: :ets.lookup(:probe_g7_keeper, k)

  @impl true
  def init(opts) do
    spawn(fn ->
      :ets.new(:probe_g7_keeper, [:named_table, :public, :set])
      Process.sleep(:infinity)
    end)

    {:ok, opts}
  end
end

defmodule Probe.R2.G7.KeeperTask do
  # The same keeper as a Task.start closure in a handler.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_cast(:setup, state) do
    Task.start(fn ->
      :ets.new(:probe_g7_keeper_task, [:named_table, :public])

      receive do
        :stop -> :ok
      end
    end)

    {:noreply, state}
  end
end

defmodule Probe.R2.G5.WhereisClauses do
  # One function, two clauses: the :safe clause asks whereis first, the
  # :fast clause reads the table bare. A reader calling fetch(k, :fast)
  # while the owner restarts crashes with ArgumentError.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def fetch(key, :safe) do
    case :ets.whereis(:probe_g5_whereis_clauses) do
      :undefined -> nil
      _ -> :ets.lookup(:probe_g5_whereis_clauses, key)
    end
  end

  def fetch(key, :fast), do: :ets.lookup(:probe_g5_whereis_clauses, key)

  @impl true
  def init(_opts) do
    :ets.new(:probe_g5_whereis_clauses, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Probe.R2.G5.WhereisNoted do
  # The reader asks whereis, logs that the table is missing, and reads
  # it anyway: the answer guards nothing.
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key) do
    if :ets.whereis(:probe_g5_whereis_noted) == :undefined do
      Logger.warning("cache table is not there yet")
    end

    :ets.lookup(:probe_g5_whereis_noted, key)
  end

  @impl true
  def init(_opts) do
    :ets.new(:probe_g5_whereis_noted, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Probe.R2.G7.Metrics do
  # A helper module: init/1 of the server below makes its named table,
  # and callers read it through lookup/1 while the server may be down.
  def setup, do: :ets.new(:probe_g7_metrics, [:named_table, :public, :set])
  def lookup(k), do: :ets.lookup(:probe_g7_metrics, k)
end

defmodule Probe.R2.G7.MetricsServer do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Probe.R2.G7.Metrics.setup()
    {:ok, opts}
  end
end

defmodule S2c.Ets.PlugOwner do
  # A plug's call/2 runs in the request's process: a named table it makes
  # is gone when the request ends.
  @behaviour S2c.Ets.Plugish
  def init(opts), do: opts

  def call(conn, _opts) do
    :ets.new(:s2c_plug_seen, [:named_table, :public])
    conn
  end
end

defmodule S2c.Ets.Strategy do
  @callback init(keyword()) :: {:ok, map()}
end

defmodule S2c.Ets.StrategyNamed do
  # The grpc strategy shape, with a NAMED table: not a value handed back.
  @behaviour S2c.Ets.Strategy
  def init(_opts) do
    :ets.new(:s2c_strategy_named, [:named_table, :public])
    {:ok, %{}}
  end
end

defmodule S2c.Ets.StrategyKept do
  # An unnamed table the strategy keeps in persistent_term, not in the
  # state it returns.
  @behaviour S2c.Ets.Strategy
  def init(_opts) do
    tid = :ets.new(:s2c_strategy_kept, [:public])
    :persistent_term.put(__MODULE__, tid)
    {:ok, %{}}
  end
end

defmodule S2c.Ets.StrategyReturned do
  # Negative: the grpc shape, the unnamed table handed back in the state.
  @behaviour S2c.Ets.Strategy
  def init(_opts) do
    tid = :ets.new(:s2c_strategy_returned, [:public])
    {:ok, %{tid: tid}}
  end
end

defmodule S2c.Ets.RatesHelper do
  def setup, do: :ets.new(:s2c_rates_helper, [:named_table, :public])
  def lookup(k), do: :ets.lookup(:s2c_rates_helper, k)
end

defmodule S2c.Ets.HelperJob do
  # An Oban job whose helper makes the named table: the job's process
  # holds it, and it goes when perform/1 returns.
  @behaviour S2c.Ets.Job
  def perform(_job) do
    S2c.Ets.RatesHelper.setup()
    :ok
  end
end

defmodule S2c.Ets.KeeperMfa do
  # The keeper spawned by MFA.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def lookup(k), do: :ets.lookup(:s2c_keeper_mfa, k)
  @impl true
  def init(o) do
    spawn(__MODULE__, :keep, [])
    {:ok, o}
  end

  def keep do
    :ets.new(:s2c_keeper_mfa, [:named_table, :public])
    Process.sleep(:infinity)
  end
end

defmodule S2c.Ets.KeeperAsync do
  # A warm-up run in an awaited task: the table the task makes is gone
  # as soon as the task returns.
  def warm do
    Task.async(fn -> :ets.new(:s2c_keeper_async, [:named_table, :public]) end)
    |> Task.await()
  end
end

defmodule S2c.Ets.KeeperHanded do
  # The keeper's fun handed to a helper that spawns it.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  @impl true
  def init(o) do
    start_worker(fn ->
      :ets.new(:s2c_keeper_handed, [:named_table, :public])
      Process.sleep(:infinity)
    end)

    {:ok, o}
  end

  defp start_worker(f), do: spawn(f)
end

defmodule S2c.Ets.KeeperSelfRead do
  # The server reads its keeper's table from its own callback: the
  # keeper, not the server, owns it.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  @impl true
  def init(o) do
    spawn(fn ->
      :ets.new(:s2c_keeper_self, [:named_table, :public])
      Process.sleep(:infinity)
    end)

    {:ok, o}
  end

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:s2c_keeper_self, k), s}
end

defmodule S2c.Ets.WhereisInverted do
  # The read on the :undefined side.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  def fetch(k) do
    case :ets.whereis(:s2c_whereis_inv) do
      :undefined -> :ets.lookup(:s2c_whereis_inv, k)
      _ -> []
    end
  end

  @impl true
  def init(o) do
    :ets.new(:s2c_whereis_inv, [:named_table, :protected])
    {:ok, o}
  end
end

defmodule S2c.Ets.WhereisOther do
  # Asks after another table, reads this one.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  def fetch(k) do
    case :ets.whereis(:s2c_whereis_elsewhere) do
      :undefined -> []
      _ -> :ets.lookup(:s2c_whereis_other, k)
    end
  end

  @impl true
  def init(o) do
    :ets.new(:s2c_whereis_other, [:named_table, :protected])
    {:ok, o}
  end
end

defmodule S2c.Ets.WhereisStored do
  # The answer is a value sent on; the read happens either way.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  def fetch(k) do
    send(self(), {:present, :ets.whereis(:s2c_whereis_stored) != :undefined})
    :ets.lookup(:s2c_whereis_stored, k)
  end

  @impl true
  def init(o) do
    :ets.new(:s2c_whereis_stored, [:named_table, :protected])
    {:ok, o}
  end
end

defmodule S2c.Ets.WhereisGuarded do
  # Negative: the read only where the table was found.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  def fetch(k) do
    case :ets.whereis(:s2c_whereis_ok) do
      :undefined -> []
      _ -> :ets.lookup(:s2c_whereis_ok, k)
    end
  end

  def fetch_if(k) do
    if :ets.whereis(:s2c_whereis_ok) != :undefined, do: :ets.lookup(:s2c_whereis_ok, k), else: []
  end

  @impl true
  def init(o) do
    :ets.new(:s2c_whereis_ok, [:named_table, :protected])
    {:ok, o}
  end
end

defmodule S2c.Ets.Counters do
  def setup, do: :ets.new(:s2c_counters, [:named_table, :public])
  def get(k), do: :ets.lookup(:s2c_counters, k)
end

defmodule S2c.Ets.CountersServer do
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @impl true
  def init(o) do
    S2c.Ets.Counters.setup()
    {:ok, o}
  end
end

defmodule S2c.Ets.CountersClient do
  # A third module reading the helper's table from its callers.
  def total(k), do: length(S2c.Ets.Counters.get(k))
end

defmodule S2c.Ets.Gauges do
  def setup, do: :ets.new(:s2c_gauges, [:named_table, :public])
  def get(k), do: :ets.lookup(:s2c_gauges, k)
end

defmodule S2c.Ets.GaugesServer do
  # Negative: the helper's table read only from the owner's own callback.
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def gauge(k), do: GenServer.call(__MODULE__, {:gauge, k})
  @impl true
  def init(o) do
    S2c.Ets.Gauges.setup()
    {:ok, o}
  end

  @impl true
  def handle_call({:gauge, k}, _from, s), do: {:reply, S2c.Ets.Gauges.get(k), s}
end

defmodule S2c.Own.AgentStart do
  # The child_spec/1 the supervisor's shorthand calls: a map with no
  # :restart, permanent. Without one the supervisor could not start it,
  # and since issue #4 its restart would be unknown, not the default.
  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

  def start_link(_),
    do: Agent.start_link(fn -> :ets.new(:s2c_own_agent, [:named_table, :public]) end)
end

defmodule S2c.Own.ProcLib do
  def start_link, do: :proc_lib.start_link(__MODULE__, :init, [self()])

  def init(parent) do
    :ets.new(:s2c_own_proclib, [:named_table, :public])
    :proc_lib.init_ack(parent, {:ok, self()})
    receive do: (:stop -> :ok)
  end
end

defmodule S2c.Own.KeeperBeside do
  use GenServer

  def start_link(o) do
    spawn(fn ->
      :ets.new(:s2c_own_beside, [:named_table, :public])
      Process.sleep(:infinity)
    end)

    GenServer.start_link(__MODULE__, o)
  end

  @impl true
  def init(o), do: {:ok, o}
end

defmodule S2c.Own.Sup do
  use Supervisor
  def start_link(o), do: Supervisor.start_link(__MODULE__, o)
  @impl true
  def init(_),
    do: Supervisor.init([S2c.Own.AgentStart, S2c.Own.KeeperBeside], strategy: :one_for_one)
end

defmodule S2c.Own2.AgentStart do
  # Unsupervised: its own start's agent holds the table, and nothing restarts it.
  def start_link(_),
    do: Agent.start_link(fn -> :ets.new(:s2c_own2_agent, [:named_table, :public]) end)
end
