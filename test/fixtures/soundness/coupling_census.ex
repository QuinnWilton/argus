defmodule Argus.Test.Soundness.Census.Coupling do
  @moduledoc """
  Suppression counterexamples and nearby variants: "Two restart
  authorities for the same child" read the child module's own
  child_spec/1 restart, not the spec the start hands the supervisor. A
  map spec does not call child_spec/1: with no `:restart` the child is
  permanent under that supervisor whatever the module says. Asserted by
  test/soundness/coupling_test.exs.
  """
end

defmodule Argus.Test.Soundness.Census.Coupling.Conn do
  @moduledoc "Its child_spec/1 says :temporary; a map spec does not use it."
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Coupling.MapManager do
  @moduledoc """
  The census program: a map spec with no `:restart`, so the connection is
  permanent under the DynamicSupervisor, and the manager also restarts it
  from :DOWN. A connection that crashes on start-up data is restarted
  twice per crash, spends the supervisor's intensity and takes the tree
  down (redix#334).
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Coupling.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_conn(%{opts: opts, conn: nil})}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn: pid} = s),
    do: {:noreply, start_conn(s)}

  defp start_conn(s) do
    spec = %{id: Conn, start: {Conn, :start_link, [s.opts]}}
    {:ok, pid} = DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Coupling.Sup, spec)
    Process.monitor(pid)
    %{s | conn: pid}
  end
end

defmodule Argus.Test.Soundness.Census.Coupling.HelperSpecManager do
  @moduledoc "The same map spec, built by a helper the start calls."
  use GenServer

  alias Argus.Test.Soundness.Census.Coupling.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_conn(%{opts: opts, conn: nil})}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn: pid} = s),
    do: {:noreply, start_conn(s)}

  defp start_conn(s) do
    {:ok, pid} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Coupling.Sup, conn_spec(s.opts))

    Process.monitor(pid)
    %{s | conn: pid}
  end

  defp conn_spec(opts), do: %{id: Conn, start: {Conn, :start_link, [opts]}}
end

defmodule Argus.Test.Soundness.Census.Coupling.PermanentMapManager do
  @moduledoc "A map spec that states `restart: :permanent` over the temporary module."
  use GenServer

  alias Argus.Test.Soundness.Census.Coupling.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_conn(%{opts: opts, conn: nil})}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn: pid} = s),
    do: {:noreply, start_conn(s)}

  defp start_conn(s) do
    spec = %{id: Conn, start: {Conn, :start_link, [s.opts]}, restart: :permanent}
    {:ok, pid} = DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Coupling.Sup, spec)
    Process.monitor(pid)
    %{s | conn: pid}
  end
end

defmodule Argus.Test.Soundness.Census.Coupling.ShorthandManager do
  @moduledoc """
  Quiet: the shorthand calls Conn.child_spec/1, which says :temporary —
  the supervisor never restarts it, and the manager is the one authority.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Coupling.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_conn(%{opts: opts, conn: nil})}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn: pid} = s),
    do: {:noreply, start_conn(s)}

  defp start_conn(s) do
    {:ok, pid} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Coupling.Sup, {Conn, s.opts})

    Process.monitor(pid)
    %{s | conn: pid}
  end
end

defmodule Argus.Test.Soundness.Census.Coupling.TemporaryMapManager do
  @moduledoc "Quiet: a map spec that states `restart: :temporary`."
  use GenServer

  alias Argus.Test.Soundness.Census.Coupling.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_conn(%{opts: opts, conn: nil})}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{conn: pid} = s),
    do: {:noreply, start_conn(s)}

  defp start_conn(s) do
    spec = %{id: Conn, start: {Conn, :start_link, [s.opts]}, restart: :temporary}
    {:ok, pid} = DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Coupling.Sup, spec)
    Process.monitor(pid)
    %{s | conn: pid}
  end
end
