defmodule Argus.Test.Fixtures.GlobalNodes do
  @moduledoc """
  One `:global` lock taken from init/1 per shape of node list: whose
  agreement the lock waits on decides whether startup calls it
  cluster-wide. `Shapes` holds the same calls outside any init/1, for
  the extractor and for blocking.
  """

  defmodule Local do
    @moduledoc "`[node()]`: only this node's global server takes part."
    use GenServer

    def init(name) do
      true = :global.set_lock({name, self()}, [node()])
      {:ok, name}
    end
  end

  defmodule Cluster do
    @moduledoc "`[node() | Node.list()]`: every connected node must agree."
    use GenServer

    def init(name) do
      true = :global.set_lock({name, self()}, [node() | Node.list()])
      {:ok, name}
    end
  end

  defmodule Default do
    @moduledoc "set_lock/1 takes the lock on every known node."
    use GenServer

    def init(name) do
      true = :global.set_lock({name, self()})
      {:ok, name}
    end
  end

  defmodule Unknown do
    @moduledoc "The node list is the caller's: a parameter the bytecode does not show."
    use GenServer

    def init({name, nodes}) do
      :ok = lock(name, nodes)
      {:ok, name}
    end

    def lock(name, nodes) do
      true = :global.set_lock({name, self()}, nodes)
      :ok
    end
  end

  defmodule Shapes do
    @moduledoc "Every node-list shape the extractor reads, outside init/1."

    def local(k), do: :global.set_lock({k, self()}, [node()])
    def local_self(k), do: :global.set_lock({k, self()}, [Node.self()])
    def cluster(k), do: :global.set_lock({k, self()}, [node() | Node.list()])
    def nodes_only(k), do: :global.set_lock({k, self()}, Node.list())
    def erl_nodes(k), do: :global.set_lock({k, self()}, [node() | :erlang.nodes()])
    def appended(k), do: :global.set_lock({k, self()}, Node.list() ++ [node()])
    def this(k), do: :global.set_lock({k, self()}, Node.list(:this))
    def default(k), do: :global.set_lock({k, self()})
    def arg(k, ns), do: :global.set_lock({k, self()}, ns)
    def named(k), do: :global.set_lock({k, self()}, [:a@host, :b@host])
    def cons_arg(k, ns), do: :global.set_lock({k, self()}, [node() | ns])
    def trans_default(k, f), do: :global.trans({k, self()}, f)
    def trans_local(k, f), do: :global.trans({k, self()}, f, [node()])
    def trans_cluster(k, f), do: :global.trans({k, self()}, f, [node() | Node.list()], 3)

    def held(k) do
      ns = [node() | Node.list()]
      true = :global.set_lock({k, self()}, ns, :infinity)
      :global.del_lock({k, self()}, ns)
    end
  end
end
