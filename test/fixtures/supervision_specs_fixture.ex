# Child specs the supervision extractor reads beyond a literal list (the
# ETS rows round: 8 of 12 sampled "ETS table dies with its owner" rows
# were permanent children it did not read), and the restart and type
# each gives its child. An owner makes a named, public table in init/1
# with no heir, so "ETS table dies with its owner" says whether its
# supervisor is known to restart it.

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
