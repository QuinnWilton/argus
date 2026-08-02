defmodule Argus.Test.Fixtures.UnboundedChildren do
  @moduledoc """
  Fixtures for unbounded dynamic children.

  `Uncapped` and `Capped` differ by one option; `Internal` differs only in
  who can reach it. Both pairs matter — the finding is neither "unbounded"
  nor "reachable" alone.
  """

  defmodule Worker do
    @moduledoc false
    use GenServer
    def start_link(o), do: GenServer.start_link(__MODULE__, o)
    @impl GenServer
    def init(o), do: {:ok, o}
  end

  defmodule UncappedSup do
    @moduledoc "No max_children: takes the :infinity default."
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule CappedSup do
    @moduledoc "The same supervisor with a ceiling."
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end

  defmodule PublicLive do
    @moduledoc "The bug: a request starts a child on the uncapped supervisor."
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      DynamicSupervisor.start_child(
        Argus.Test.Fixtures.UnboundedChildren.UncappedSup,
        Argus.Test.Fixtures.UnboundedChildren.Worker
      )

      {:noreply, socket}
    end

    def render(assigns), do: assigns
  end

  defmodule CappedLive do
    @moduledoc "Same request path, but the supervisor has a ceiling."
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      DynamicSupervisor.start_child(
        Argus.Test.Fixtures.UnboundedChildren.CappedSup,
        Argus.Test.Fixtures.UnboundedChildren.Worker
      )

      {:noreply, socket}
    end

    def render(assigns), do: assigns
  end

  defmodule Internal do
    @moduledoc """
    Uncapped, but only reachable from code the operator drives. Most dynamic
    supervisors are this, and reporting them would bury the ones an outside
    party can drive.
    """
    def boot do
      DynamicSupervisor.start_child(
        Argus.Test.Fixtures.UnboundedChildren.UncappedSup,
        Argus.Test.Fixtures.UnboundedChildren.Worker
      )
    end
  end
end
