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
  # The one fun init/1 builds goes into a child spec: it waits in the
  # child, not in init's process.
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  @impl true
  def init(sup) do
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

    {:ok, sup}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.HandsOffAndWaits do
  @moduledoc false
  # init/1 starts a child around one fun and waits on each peer in an
  # Enum.each closure: two closures, so neither is taken for the child's,
  # and the wait is init's.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({sup, peers}) do
    Supervisor.start_child(sup, %{id: :worker, start: {Task, :start_link, [fn -> :ok end]}})

    Enum.each(peers, fn peer ->
      receive do
        {:ready, ^peer} -> :ok
      end
    end)

    {:ok, peers}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.TaskCalls do
  @moduledoc false
  # init/1 starts a task that calls a sibling the supervisor starts
  # later: the task waits, init does not, and the start is no deadlock.

  defmodule Early do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.InitRecv.TaskCalls.Later

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, _task} = Task.start_link(fn -> Later.warm() end)
      {:ok, nil}
    end
  end

  defmodule Later do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def warm, do: GenServer.call(__MODULE__, :warm)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:warm, _from, s), do: {:reply, :ok, s}
  end

  defmodule Sup do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.InitRecv.TaskCalls.{Early, Later}

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: Supervisor.init([Early, Later], strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AcksThenLoops do
  @moduledoc false
  # OTP's logger_olp: started with :proc_lib.start_link, init/1 acks its
  # start and then becomes the server with :gen_server.enter_loop. The
  # server loop's receive runs after the starter got its answer.
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(__MODULE__, [], opts)
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AcksThenWaits do
  @moduledoc false
  # The same ack, then a receive of init/1's own and a loop it calls:
  # both after the start.
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    :proc_lib.init_ack({:ok, self()})

    receive do
      {:go, config} -> serve({opts, config})
    end
  end

  defp serve(state) do
    receive do
      {:work, from} ->
        send(from, {:done, state})
        serve(state)
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.WaitsBeforeAck do
  @moduledoc false
  # The receive comes before the ack: the starter waits for it.
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    config =
      receive do
        {:go, config} -> config
      end

    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(__MODULE__, [], {opts, config})
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AsksWithMonitor do
  @moduledoc false
  # code_server's call/1 and gen's call: a request whose wait takes the
  # :DOWN of the monitor on the process asked. If that process is gone,
  # the :DOWN comes.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(server), do: {:ok, ask(server, :config)}

  defp ask(server, request) do
    ref = Process.monitor(server)
    send(server, {:ask, self(), ref, request})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, _, _, reason} ->
        exit(reason)
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AwaitsHandedDown do
  @moduledoc false
  # proc_lib's await_DOWN/2: the wait pins a ref its caller took, handed
  # in; and code's do_par/2, a spawn_monitor's pair.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    await_down(pid, ref)
    {:ok, run_aside(fn -> :done end)}
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  defp run_aside(fun) do
    {_pid, ref} = spawn_monitor(fn -> exit(fun.()) end)

    receive do
      {:DOWN, ^ref, :process, _, result} -> result
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.ClosesPort do
  @moduledoc false
  # peer's init/1: trapping exits, it closes the port it opened and waits
  # for that port's exit signal, which closing it sends.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(exec) do
    Process.flag(:trap_exit, true)
    port = Port.open({:spawn_executable, exec}, [:binary])
    Port.close(port)

    receive do
      {:EXIT, ^port, _} -> :ok
    end

    {:ok, exec}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.FlushesTimer do
  @moduledoc false
  # Livebook's session: cancel_timer said the timer fired, and the
  # receive takes the message it already delivered.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :close, 60_000)

    if Process.cancel_timer(ref) == false do
      receive do
        :close -> :ok
      end
    end

    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.LoopsOnParent do
  @moduledoc false
  # A loop init/1 enters before any ack, whose receive also takes the
  # parent's exit: that clause ends the loop, and the loop still waits
  # for its next message from anyone.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(parent), do: {:ok, loop(parent, [])}

  defp loop(parent, acc) do
    receive do
      {:EXIT, ^parent, _} -> acc
      {:item, item} -> loop(parent, [item | acc])
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.AsksByHand do
  @moduledoc false
  # A hand-written request to a sibling, and a wait for its answer or its
  # :DOWN. The :DOWN ends the wait if the sibling dies; a sibling that
  # lives and never answers (one that calls this server while it starts)
  # holds the start as long as it lives.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(peer) do
    pid = Process.whereis(peer)
    ref = Process.monitor(pid)
    send(pid, {:get_config, self(), ref})

    receive do
      {^ref, config} -> {:ok, config}
      {:DOWN, ^ref, _, _, _} -> {:stop, :peer_down}
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.UnlinkedExit do
  @moduledoc false
  # A worker spawned WITHOUT a link, and a wait for its answer or its
  # :EXIT. No link and no trap_exit: the :EXIT never comes, and a worker
  # that crashes first holds the start forever.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(arg) do
    parent = self()
    pid = spawn(fn -> send(parent, {:done, self(), arg}) end)

    receive do
      {:done, ^pid, result} -> {:ok, result}
      {:EXIT, ^pid, reason} -> {:stop, reason}
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.LinkedUntrapped do
  @moduledoc false
  # Linked, but not trapping exits: the :EXIT arrives as a signal, not a
  # message. A worker that exits :normal before it sends leaves the wait
  # with nothing to take.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(arg) do
    parent = self()
    pid = spawn_link(fn -> send(parent, {:done, self(), arg}) end)

    receive do
      {:done, ^pid, result} -> {:ok, result}
      {:EXIT, ^pid, reason} -> {:stop, reason}
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.CancelsHanded do
  @moduledoc false
  # Cancels a timer its caller handed it, without looking at the result,
  # then waits for a config message that is no timer's.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.cancel_timer(opts.timer)

    receive do
      {:config, config} -> {:ok, config}
    end
  end
end

defmodule Argus.Test.Fixtures.InitRecv.FlushesUnchecked do
  @moduledoc false
  # Cancels its own timer and waits for the timer's message whatever the
  # cancel said: when the cancel succeeded, the message never comes.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :close, 60_000)
    Process.cancel_timer(ref)

    receive do
      :close -> :ok
    end

    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.FlushesOnFalse do
  @moduledoc false
  # gen_server's mc_cancel_timer/2: the flush on the `false` clause of a
  # case on the cancel.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = :erlang.start_timer(1_000, self(), :close)

    case :erlang.cancel_timer(ref) do
      false ->
        receive do
          {:timeout, ^ref, :close} -> :ok
        end

      _ ->
        :ok
    end

    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.InitRecv.EntersWithoutAck do
  @moduledoc false
  # Started by GenServer.start_link, init/1 enters the loop itself: it
  # never returns and nothing acknowledged the start.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: :gen_server.enter_loop(__MODULE__, [], state)

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Argus.Test.Fixtures.InitRecv.FlushesUnlessCancelled do
  @moduledoc false
  # The flush written the other way round: nothing to do when the cancel
  # stopped the timer, a receive for its message when it had fired.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :close, 60_000)

    if Process.cancel_timer(ref) != false do
      {:ok, opts}
    else
      receive do
        :close -> {:ok, opts}
      end
    end
  end
end
