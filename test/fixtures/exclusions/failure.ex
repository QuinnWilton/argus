# Shapes the failure analysis keeps quiet through an exclusion no
# evaluation program exercises (census 2026-09-26); see
# `test/exclusions/failure_test.exs` and docs/design/exclusions.md.

# Leader cleanup over a :global name whose holder is usually on another
# node, probing the pid through a helper. Process.alive?/1 raises
# badarg on a remote pid; here the helper probes bare, so the cleanup
# crashes whenever the holder is remote.
defmodule Excl.Failure.RemoteProbe.Bare do
  @moduledoc false
  def cleanup(name) do
    pid = :global.whereis_name(name)
    if alive?(pid), do: :ok, else: :global.unregister_name(name)
  end

  defp alive?(pid), do: Process.alive?(pid)
end

# The same cleanup whose helper takes the ArgumentError itself: the
# probe the caller makes through it is handled where it raises, though
# the caller has no rescue of its own.
defmodule Excl.Failure.RemoteProbe.HelperRescues do
  @moduledoc false
  def cleanup(name) do
    pid = :global.whereis_name(name)
    if alive?(pid), do: :ok, else: :global.unregister_name(name)
  end

  defp alive?(pid) do
    try do
      Process.alive?(pid)
    rescue
      ArgumentError -> false
    end
  end
end

# nebulex#140-style remote cache get over :erpc.call. The rescue unwraps
# the remote exception but has no clause for a transport failure: a
# {:erpc, :noconnection} reaches the case and raises a CaseClauseError.
defmodule Excl.Failure.ErpcTransport.Unwrapped do
  @moduledoc false
  def get(node, key) do
    try do
      :erpc.call(node, :ets, :lookup, [:cache, key])
    rescue
      e in ErlangError ->
        case e.original do
          {:exception, reason, _stack} -> {:error, reason}
        end
    end
  end
end

# The same get whose catch takes the transport failure by its tag first
# (`:error, {:erpc, reason}`) and unwraps the remote exception in a
# second clause: no {:erpc, _} reaches the inner case.
defmodule Excl.Failure.ErpcTransport.CaughtByTag do
  @moduledoc false
  def get(node, key) do
    try do
      :erpc.call(node, :ets, :lookup, [:cache, key])
    catch
      :error, {:erpc, reason} ->
        {:error, {:node_down, reason}}

      :error, reason ->
        case reason do
          {:exception, r, _stack} -> {:error, r}
        end
    end
  end
end

# Horde-style liveness check over :erpc.call, which raises on a gone
# node. Unguarded: a node that goes away crashes the caller.
defmodule Excl.Failure.ErpcBool.Bare do
  @moduledoc false
  def alive?(node, pid), do: :erpc.call(node, Process, :alive?, [pid])
end

# The same check under a rescue of every exception: a gone node answers
# false.
defmodule Excl.Failure.ErpcBool.RescuesAll do
  @moduledoc false
  def alive?(node, pid) do
    try do
      :erpc.call(node, Process, :alive?, [pid])
    rescue
      _ -> false
    end
  end
end

# The same check catching the transport failure by its tag (the fix
# Horde took): a gone node answers false.
defmodule Excl.Failure.ErpcBool.CatchesTag do
  @moduledoc false
  def alive?(node, pid) do
    try do
      :erpc.call(node, Process, :alive?, [pid])
    catch
      :error, {:erpc, _} -> false
    end
  end
end

# The tagged catch around a branch on the call's boolean: a gone node
# routes to :dead instead of crashing.
defmodule Excl.Failure.ErpcBool.CatchesTagAroundIf do
  @moduledoc false
  def route(node, pid, msg) do
    try do
      if :erpc.call(node, Process, :alive?, [pid]) == true, do: send(pid, msg), else: :dead
    catch
      :error, {:erpc, _} -> :dead
    end
  end
end

# A worker started with :proc_lib.start that loops after its ack, and
# nothing watches it past the ack: if it dies, no one hears.
defmodule Excl.Failure.WatchedStart.Unwatched do
  @moduledoc false
  def start_worker, do: :proc_lib.start(__MODULE__, :init_worker, [self()])

  def init_worker(parent) do
    :proc_lib.init_ack(parent, {:ok, self()})
    loop()
  end

  defp loop do
    receive do
      {:work, from} ->
        send(from, :done)
        loop()
    end
  end
end

# The same worker whose starter monitors it once it is up: its :DOWN
# tells the starter when it dies.
defmodule Excl.Failure.WatchedStart.Monitored do
  @moduledoc false
  def start_worker do
    {:ok, pid} = :proc_lib.start(__MODULE__, :init_worker, [self()])
    ref = Process.monitor(pid)
    {:ok, pid, ref}
  end

  def init_worker(parent) do
    :proc_lib.init_ack(parent, {:ok, self()})
    loop()
  end

  defp loop do
    receive do
      {:work, from} ->
        send(from, :done)
        loop()
    end
  end
end

# A cache client whose calls to the :cache server are guarded against
# its exit everywhere but in fetch/1: there a try covers the call only
# to time it (an `after`), and fetch/1's one caller rescues KeyError,
# not the :noproc exit. The deviant is reported once, as covered by a
# try that takes nothing; its caller's rescue is the same site's second
# cover, not a second deviation.
defmodule Excl.Failure.BareCover.Client do
  @moduledoc false
  def get(key) do
    try do
      GenServer.call(:excl_cache, {:get, key})
    catch
      :exit, _ -> nil
    end
  end

  def put(key, value) do
    try do
      GenServer.call(:excl_cache, {:put, key, value})
    catch
      :exit, _ -> :error
    end
  end

  def delete(key) do
    try do
      GenServer.call(:excl_cache, {:delete, key})
    catch
      :exit, _ -> :error
    end
  end

  def refresh(key) do
    try do
      fetch(key)
    rescue
      e in KeyError -> {:error, e}
    end
  end

  defp fetch(key) do
    started = System.monotonic_time()

    try do
      GenServer.call(:excl_cache, {:get, key})
    after
      IO.puts(:stderr, "cache fetch took #{System.monotonic_time() - started}")
    end
  end
end

# A mailer that runs deliveries under a Task.Supervisor. Three sites
# check the start's result; notify/1 drops it, so a full supervisor
# (max_children) loses the delivery silently. The unchecked result is
# its own finding at that site; the consistency rule must not report
# the same site a second time.
defmodule Excl.Failure.StartChildBelief.Mailer do
  @moduledoc false
  @sup Excl.Failure.StartChildBelief.TaskSup

  # The supervisor the starts name has a cap: a start can fail.
  def child_spec(_arg), do: {Task.Supervisor, name: @sup, max_children: 100}

  def welcome(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :welcome) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def reset(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :reset) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def receipt(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :receipt) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def notify(user) do
    Task.Supervisor.start_child(@sup, fn -> deliver(user, :notice) end)
    :ok
  end

  defp deliver(user, kind), do: IO.puts("#{kind} -> #{user}")
end

defmodule Excl.Failure.StartChildBelief.UncappedMailer do
  @moduledoc false
  @sup Excl.Failure.StartChildBelief.UncappedSup

  # No cap: no start can fail, and a dropped result hides nothing.
  def child_spec(_arg), do: {Task.Supervisor, name: @sup}

  def welcome(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :welcome) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def reset(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :reset) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def receipt(user) do
    case Task.Supervisor.start_child(@sup, fn -> deliver(user, :receipt) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def notify(user) do
    Task.Supervisor.start_child(@sup, fn -> deliver(user, :notice) end)
    :ok
  end

  defp deliver(user, kind), do: IO.puts("#{kind} -> #{user}")
end
