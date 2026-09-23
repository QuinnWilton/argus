defmodule Argus.Test.Fixtures.InitRecv do
  @moduledoc false

  defmodule Blocking do
    @moduledoc false
    # postgrex#746: a handshake in init/1 that waits on the socket forever.
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock) do
      case handshake(sock) do
        {:ok, greeting} -> {:ok, %{sock: sock, greeting: greeting}}
        {:error, reason} -> {:stop, reason}
      end
    end

    defp handshake(sock), do: msg_recv(sock, :infinity)

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule Bounded do
    @moduledoc false
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock) do
      case msg_recv(sock, 5000) do
        {:ok, greeting} -> {:ok, %{sock: sock, greeting: greeting}}
        {:error, reason} -> {:stop, reason}
      end
    end

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule Later do
    @moduledoc false
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock), do: {:ok, sock}

    @impl true
    def handle_info(:read, sock) do
      _ = msg_recv(sock, :infinity)
      {:noreply, sock}
    end

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.Waits do
  @moduledoc false
  # A receive with no `after` on init's path waits the same way.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(parent) do
    send(parent, {:ready, self()})
    {:ok, await_go()}
  end

  defp await_go do
    receive do
      {:go, config} -> config
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.SpawnsLoop do
  @moduledoc false
  # init/1 spawns a loop that waits forever: the wait is the loop's
  # process's, and init returns at once.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    pid = spawn_link(fn -> loop(opts) end)
    {:ok, pid}
  end

  defp loop(opts) do
    receive do
      {:work, from} ->
        send(from, {:done, opts})
        loop(opts)
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.SpawnsWork do
  @moduledoc false
  # A connect, a cluster-wide lock and a supervisor query in a task
  # init/1 starts: none holds the start, and a failed connect does not
  # fail init.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init({host, port}) do
    {:ok, task} = Task.start_link(fn -> connect(host, port) end)
    {:ok, task}
  end

  defp connect(host, port) do
    :global.set_lock({:connect, self()}, [node()])
    _ = Supervisor.which_children(:connections)
    :gen_tcp.connect(host, port, [:binary, active: false])
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AwaitsEach do
  @moduledoc false
  # A closure handed to Enum.each runs in init/1's own process: its
  # receive holds the start as surely as one written in init.
  use GenServer

  def start_link(peers), do: GenServer.start_link(__MODULE__, peers)

  @impl true
  def init(peers) do
    Enum.each(peers, fn peer ->
      send(peer, {:hello, self()})

      receive do
        {:ack, ^peer} -> :ok
      end
    end)

    {:ok, peers}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.HandsOff do
  @moduledoc false
  # Funs init/1 hands to Task.async_stream and to a child spec: each
  # waits in the process that runs it, not in init's.
  use GenServer

  def start_link(peers), do: GenServer.start_link(__MODULE__, peers)

  @impl true
  def init({sup, peers}) do
    peers
    |> Task.async_stream(fn peer ->
      receive do
        {:ready, ^peer} -> peer
      end
    end)
    |> Stream.run()

    Supervisor.start_child(sup, %{
      id: :watcher,
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]}
    })

    {:ok, peers}
  end
end
