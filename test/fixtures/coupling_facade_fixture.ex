defmodule Argus.Test.Fixtures.FacadeSupervisor do
  @moduledoc """
  The shape the module-level dependency in calls.dl cannot judge: under
  one_for_one, `FacadeCaller` reaches a *pure* function of `FacadeHelper`,
  and `FacadeHelper` happens to call a server from another function. No
  resolved call or cast connects the two; the third clause of
  `stateful_module_dep` reports a coupling anyway. A prior that says
  the helper's API does not message a process is what tells this apart
  from a facade reached through delegation.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Argus.Test.Fixtures.FacadeCaller, []},
      {Argus.Test.Fixtures.FacadeHelper, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.FacadeCaller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:scale, n}, _from, state) do
    {:reply, Argus.Test.Fixtures.FacadeHelper.scale(n), state}
  end
end

defmodule Argus.Test.Fixtures.FacadeHelper do
  @moduledoc false

  def child_spec(_opts) do
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> %{} end, [name: __MODULE__]]}}
  end

  # Pure: the caller reaches this and nothing else.
  def scale(n), do: n * 10

  # A call, elsewhere in the module: enough for the module-level clause.
  def remember(key, value), do: GenServer.call(__MODULE__, {:remember, key, value})
end
