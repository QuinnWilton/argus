# Deliberately-imprecise fixtures for the coverage meta-analysis.
#
# Each module below exists to trigger exactly one shape-gap relation
# in priv/dl/analyses/coverage.dl or to produce a specific imprecision
# event category when the extractors run with tracing enabled. The
# coverage analysis test asserts that each relation fires for the
# corresponding fixture.
#
# These modules are NOT intended to be runnable — they only need to
# survive compilation so beam_spy can disassemble them. Some of them
# reference modules that don't exist at runtime; that's fine because
# the analyses operate on bytecode, not a live system.

defmodule Argus.Test.Fixtures.CoverageDynamicCalls do
  @moduledoc false

  # GenServer.call with a runtime-resolved target — resolve_callee in
  # the OTP extractor returns "dynamic", which should emit
  # genserver_callee imprecision.
  def call_runtime(server) do
    GenServer.call(server, :ping)
  end

  def call_via_lookup(registry, key) do
    pid = :erlang.whereis(key)
    GenServer.call({registry, pid}, :status)
  end
end

defmodule Argus.Test.Fixtures.CoverageEmptySupervisor do
  @moduledoc false
  use Supervisor

  # Supervisor whose children are built via Enum.map — the child-spec
  # scanner in the extractor can't recover individual modules from a
  # runtime comprehension, so supervisor_child fires zero times and
  # coverage_supervisor_no_children should match this module.
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(specs) do
    children = Enum.map(specs, fn {mod, args} -> {mod, args} end)
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.CoverageDeadEts do
  @moduledoc false
  use GenServer

  # Creates a named ETS table and never reads or writes it anywhere in
  # the corpus — coverage_ets_unused should match :coverage_dead_cache.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    :ets.new(:coverage_dead_cache, [:set, :named_table, :public])
    {:ok, nil}
  end
end

defmodule Argus.Test.Fixtures.CoverageIsolatedGenServer do
  @moduledoc false
  use GenServer

  # A GenServer that nothing else in the fixture set calls — it should
  # match coverage_genserver_isolated when the coverage analysis runs
  # against only the fixtures in this file.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}
end

defmodule Argus.Test.Fixtures.CoveragePidServer do
  @moduledoc false
  # Called only through the pid its start returns: traffic points-to sees.
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
end

defmodule Argus.Test.Fixtures.CoverageNamedByPid do
  @moduledoc false
  # Registered under its name, called through the pid a whereis returns.
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
end

defmodule Argus.Test.Fixtures.CoveragePidClient do
  @moduledoc false
  alias Argus.Test.Fixtures.{CoverageNamedByPid, CoveragePidServer}

  def ping do
    {:ok, pid} = CoveragePidServer.start_link()
    GenServer.call(pid, :ping)
  end

  def ping_named do
    pid = Process.whereis(CoverageNamedByPid)
    GenServer.call(pid, :ping)
  end
end
