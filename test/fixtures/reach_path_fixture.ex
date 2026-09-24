defmodule Argus.Test.Fixtures.ReachPath do
  @moduledoc """
  Findings whose site sits in a helper the entry reaches: the related
  frame naming the entry should point at the call that starts the path,
  not at the entry's head. The tests find each expected line by the call's
  own text, so the fixture can move without editing them.
  """

  defmodule ClusterLock do
    @moduledoc "init/1 reaches a cluster-wide lock one call down."
    use GenServer

    def init(name) do
      :ok = join(name)
      :ok = lock(name)
      {:ok, name}
    end

    def join(name), do: :pg.join(name, self())

    def lock(name) do
      true = :global.set_lock({name, self()}, [node()])
      :ok
    end
  end

  defmodule TwoPaths do
    @moduledoc "Two calls in init/1 reach the same lock; the earlier one is the path."
    use GenServer

    def init(name) do
      :ok = prepare(name)
      :ok = acquire(name)
      {:ok, name}
    end

    def prepare(name), do: take(name)
    def acquire(name), do: take(name)

    def take(name) do
      true = :global.set_lock({name, self()}, [node()])
      :ok
    end
  end

  defmodule WaitsInInit do
    @moduledoc "init/1 reaches a receive with no `after` through a helper."
    use GenServer

    def init(arg) do
      :ok = await_ready()
      {:ok, arg}
    end

    def await_ready do
      receive do
        :ready -> :ok
      end
    end
  end

  defmodule Directory do
    @moduledoc "A sibling the writer unregisters from."
    use GenServer

    def init(:ok), do: {:ok, %{}}
    def handle_call({:unregister, name}, _from, names), do: {:reply, :ok, Map.delete(names, name)}
  end

  defmodule Writer do
    @moduledoc "terminate/2 reaches the sibling through a helper."
    use GenServer

    def init(path) do
      Process.flag(:trap_exit, true)
      File.open(path, [:write])
    end

    def terminate(_reason, file) do
      unregister()
      File.close(file)
    end

    def unregister do
      :ok = GenServer.call(Argus.Test.Fixtures.ReachPath.Directory, {:unregister, __MODULE__})
    end
  end

  defmodule EachWriter do
    @moduledoc "Horde's shape: the sibling call is in a closure written inside terminate/2."
    use GenServer

    def init(names) do
      Process.flag(:trap_exit, true)
      {:ok, names}
    end

    def terminate(_reason, names) do
      Enum.each(names, fn name ->
        :ok = GenServer.call(Argus.Test.Fixtures.ReachPath.Directory, {:unregister, name})
      end)
    end
  end

  defmodule EachTree do
    @moduledoc "Starts the closure-calling writer first, then the directory."
    use Supervisor

    def init(:ok) do
      Supervisor.init(
        [Argus.Test.Fixtures.ReachPath.EachWriter, Argus.Test.Fixtures.ReachPath.Directory],
        strategy: :one_for_one
      )
    end
  end

  defmodule Tree do
    @moduledoc "Starts the writer first, then the directory it unregisters from."
    use Supervisor

    def init(:ok) do
      Supervisor.init(
        [Argus.Test.Fixtures.ReachPath.Writer, Argus.Test.Fixtures.ReachPath.Directory],
        strategy: :one_for_one
      )
    end
  end
end
