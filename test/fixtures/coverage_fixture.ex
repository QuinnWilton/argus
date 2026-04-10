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

defmodule Argus.Test.Fixtures.CoverageStatemNoTransitions do
  @moduledoc false
  @behaviour :gen_statem

  # gen_statem with two states whose handlers return the bare atom
  # :keep_state_and_data instead of a tuple. Bare atom returns don't
  # flow through put_tuple2 so scan_return_tuples sees nothing —
  # statem_state facts still fire (one per state function), but
  # statem_transition fires zero times, which is exactly the shape
  # coverage_statem_no_transitions is meant to catch.
  def callback_mode, do: :state_functions

  def init(_), do: {:ok, :idle, %{}}

  def idle(:info, _event, _data) do
    :keep_state_and_data
  end

  def busy(:info, _event, _data) do
    :keep_state_and_data
  end

  def terminate(_reason, _state, _data), do: :ok
  def code_change(_old, state, data, _extra), do: {:ok, state, data}
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
