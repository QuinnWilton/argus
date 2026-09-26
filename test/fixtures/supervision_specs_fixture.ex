# Child specs the supervision extractor reads beyond a literal list (the
# ETS rows round: 8 of 12 sampled "ETS table dies with its owner" rows
# were permanent children it did not read). Each owner makes a named,
# public table in init/1 with no heir, so "ETS table dies with its owner"
# says whether its supervisor is known to restart it: quiet for an owner
# a supervisor restarts, reported for one no spec the extractor can read
# makes a permanent child. spec_helper_sup.erl and spec_start_child.erl
# (test/fixtures/erl) name the owners the Erlang shapes start.

for {owner, table} <- [
      HelperOwner: :specs_helper,
      ModulesOwner: :specs_modules,
      HelperTempOwner: :specs_helper_temp,
      EnvOwner: :specs_env,
      AddedOwner: :specs_added,
      AddedMapOwner: :specs_added_map,
      AddedTempOwner: :specs_added_temp,
      AddedParamOwner: :specs_added_param,
      AddedDynOwner: :specs_added_dyn,
      AppendedOwner: :specs_appended,
      OptionalOwner: :specs_optional,
      RejectedOwner: :specs_rejected,
      OverriddenOwner: :specs_overridden,
      RuntimeMapOwner: :specs_runtime_map,
      RuntimeRestartOwner: :specs_runtime_restart,
      StartedOwner: :specs_started,
      StartedTempOwner: :specs_started_temp,
      DynamicOwner: :specs_dynamic
    ] do
  defmodule Module.concat(Argus.Test.Fixtures.ChildSpecs, owner) do
    @moduledoc false
    use GenServer

    @table table

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init(_arg) do
      :ets.new(@table, [:named_table, :public, :set])
      {:ok, nil}
    end
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.MapOwner do
  @moduledoc false
  # A hand-written child_spec/1 map with no :restart, which a list names by
  # calling it (logflare's ClickHouse CircuitBreaker): permanent by the
  # supervisor's default.
  use GenServer

  def child_spec(arg), do: %{id: {__MODULE__, arg}, start: {__MODULE__, :start_link, [arg]}}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ets.new(:specs_map, [:named_table, :public, :set])
    {:ok, nil}
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.Remote do
  @moduledoc false
  # Children another module decides: the extractor does not read them.
  def children, do: Application.get_env(:specs, :children, [])
end

defmodule Argus.Test.Fixtures.ChildSpecs.AppendedApp do
  @moduledoc false
  # A child list joined with ++ around helpers and another module's list
  # (hexpm's, nerves_hub_web's and supavisor's Application): every child
  # a part shows is a child, in order, and the list is open.
  use Application

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  @impl true
  def start(_type, _args) do
    children =
      [{Registry, keys: :unique, name: Specs.Registry}] ++
        optional_children() ++
        [Specs.AppendedOwner, Specs.MapOwner.child_spec(:primary)] ++
        Specs.Remote.children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Specs.Supervisor)
  end

  defp optional_children do
    if Application.get_env(:specs, :optional, false), do: [Specs.OptionalOwner], else: []
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.RejectSup do
  @moduledoc false
  # `Enum.reject(&is_nil/1)` over the child list keeps every child it
  # shows (hexpm's common_children/1): the list stays closed.
  use Supervisor

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    [Specs.RejectedOwner, {Registry, keys: :unique, name: Specs.RejectRegistry}]
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.PredicateSup do
  @moduledoc false
  # Any other predicate may drop a child the list shows: the list is open.
  use Supervisor

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    [Specs.Remote, {Registry, keys: :unique, name: Specs.PredicateRegistry}]
    |> Enum.reject(&disabled?/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp disabled?(child), do: child in Application.get_env(:specs, :disabled, [])
end

defmodule Argus.Test.Fixtures.ChildSpecs.OverrideSup do
  @moduledoc false
  # Supervisor.child_spec/2's overrides are the child's restart when they
  # state one; a map built at run time takes the supervisor's default
  # restart when it states none, and none the extractor can name when its
  # restart comes from a call.
  use Supervisor

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    children = [
      Supervisor.child_spec({Specs.OverriddenOwner, []}, restart: :temporary),
      %{id: :runtime, start: {Specs.RuntimeMapOwner, :start_link, [arg]}},
      %{id: :restart, start: {Specs.RuntimeRestartOwner, :start_link, [arg]}, restart: restart()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp restart, do: Application.get_env(:specs, :restart, :permanent)
end

defmodule Argus.Test.Fixtures.ChildSpecs.Starter do
  @moduledoc false
  # Children a start_child adds: to a Supervisor with its own spec, and to
  # a DynamicSupervisor through the child's child_spec/1.
  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  def start_permanent, do: Supervisor.start_child(Specs.Supervisor, {Specs.StartedOwner, []})

  def start_temporary(arg) do
    Supervisor.start_child(Specs.Supervisor, %{
      id: :temp,
      start: {Specs.StartedTempOwner, :start_link, [arg]},
      restart: :temporary
    })
  end

  def start_dynamic(arg),
    do: DynamicSupervisor.start_child(Specs.Pool, Specs.DynamicOwner.child_spec(arg))

  # redix e67e61a's shape: the override is the restart this start states.
  def start_dynamic_temporary(arg) do
    spec = Supervisor.child_spec({Specs.DynamicOwner, arg}, restart: :temporary)
    DynamicSupervisor.start_child(Specs.Pool, spec)
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.NamedPoolsApp do
  @moduledoc false
  # A helper handed each pool's name builds `{DynamicSupervisor, name:
  # name}` (DBConnection.App's dynamic_supervisor/1): two children, each
  # known by the name the call passes.
  use Application

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  @impl true
  def start(_type, _args) do
    children = [
      pool(Specs.FirstPool),
      pool(Specs.SecondPool)
    ]

    Supervisor.start_link(children, strategy: :one_for_all, name: Specs.NamedPools)
  end

  defp pool(name) do
    Supervisor.child_spec({DynamicSupervisor, name: name, strategy: :one_for_one}, id: name)
  end
end

defmodule Argus.Test.Fixtures.ChildSpecs.TransientOwner do
  @moduledoc false
  # A shorthand's restart is the child's own child_spec/1's: `use
  # GenServer, restart: :transient` is not restarted after a normal stop,
  # and its table is gone for good.
  use GenServer, restart: :transient

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ets.new(:specs_transient, [:named_table, :public, :set])
    {:ok, nil}
  end

  @impl true
  def handle_cast(:done, state), do: {:stop, :normal, state}
end

defmodule Argus.Test.Fixtures.ChildSpecs.ProvisionerLike do
  @moduledoc false
  # logflare's ClickHouse Provisioner: a hand-written transient child_spec/1
  # a list names by calling it, and a stop once its work is done.
  use GenServer

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :transient}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg, {:continue, :work}}

  @impl true
  def handle_continue(:work, state), do: {:stop, :normal, state}
end

defmodule Argus.Test.Fixtures.ChildSpecs.PermanentStopper do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_cast(:done, state), do: {:stop, :normal, state}
end

defmodule Argus.Test.Fixtures.ChildSpecs.RestartSup do
  @moduledoc false
  use Supervisor

  alias Argus.Test.Fixtures.ChildSpecs, as: Specs

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    Supervisor.init(
      [
        {Specs.TransientOwner, arg},
        Specs.ProvisionerLike.child_spec(arg),
        {Specs.PermanentStopper, arg}
      ],
      strategy: :one_for_one
    )
  end
end
