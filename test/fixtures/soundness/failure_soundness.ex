defmodule Probe.R2.G5.LogInline do
  # The work is the log line's argument: the entry is applied (a side
  # effect) inside the log call, and a crash applying it -- a bug in
  # apply_entry!/2 -- is swallowed by the catch-all with no trace.
  # Nearest real shape to LogicRescue.apply_and_log_result/1 (the fixture
  # that stays reported), with the work inlined into the log arguments.
  def apply_and_log(table, entry) do
    try do
      :logger.info("applied: ~p", [apply_entry!(table, entry)])
    catch
      _, _ -> :ok
    end
  end

  def apply_entry!(table, entry) do
    true = :ets.insert(table, {Map.fetch!(entry, :key), Map.fetch!(entry, :value)})
    Map.fetch!(entry, :index) + 1
  end
end

defmodule Probe.R2.G5.LogDynamic do
  # A write-ahead log whose module the state configures: `wal.log(entry)`
  # is the durable append, not a log line. A catch-all around it hides
  # a failed append (the entry is lost, the caller goes on).
  def append(wal, entry) do
    try do
      wal.log(entry)
    catch
      _, _ -> :ok
    end
  end
end

defmodule Probe.R2.G5.RoleApi do
  # A client API that dispatches on its argument: a role nothing
  # handles is a FunctionClauseError -- the caller's bug, raised in the
  # caller's process, not a peer's failure.
  def query(:primary, q), do: GenServer.call(Probe.R2.G5.Primary, {:query, q})
  def query(:replica, q), do: GenServer.call(Probe.R2.G5.Replica, {:query, q})

  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)
end

defmodule Probe.R2.G5.RoleCaller do
  # The catch-all meant for a dead peer also takes the caller's own
  # FunctionClauseError (a role from config nothing handles; a name is no pid): every
  # query silently answers :unavailable.
  def read(role, q) do
    try do
      Probe.R2.G5.RoleApi.query(role, q)
    catch
      _, _ -> :unavailable
    end
  end

  def health(name) do
    try do
      Probe.R2.G5.RoleApi.status(name)
    catch
      _, _ -> :unknown
    end
  end
end

defmodule Probe.R2.G10.BoundaryErpc do
  # erpc returns the remote function's exception to the caller as an
  # error; the remote process logs nothing. The catch-all turns the
  # program's own KeyError on the remote node into a silent nil.
  def fetch_remote(node, key) do
    try do
      :erpc.call(node, __MODULE__, :lookup, [key])
    catch
      _, _ -> nil
    end
  end

  def lookup(key), do: Map.fetch!(%{a: 1}, key)
end

defmodule Probe.R2.G10.BoundaryStartChild do
  # Supervisor.start_child/2 builds the child spec in the CALLER
  # (Supervisor.child_spec/2): a module without child_spec/1 raises
  # ArgumentError here, a bug of this program, and the catch-all makes it
  # silence.
  def start_worker(sup, arg) do
    try do
      Supervisor.start_child(sup, {Probe.R2.G10.NoChildSpec, arg})
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  def start_worker_rescue(sup, arg) do
    try do
      Supervisor.start_child(sup, {Probe.R2.G10.NoChildSpec, arg})
    rescue
      _ -> {:error, :unavailable}
    end
  end
end

defmodule Probe.R2.G10.NoChildSpec do
  def start_link(arg), do: {:ok, spawn_link(fn -> arg end)}
end

defmodule Probe.R2.G10.WhereisBifValue do
  # The comparison's boolean is recorded as a status value, and the pid
  # is then sent to whatever it is: when :probe_listener is not
  # registered, send(nil, event) raises badarg. The comparison checks
  # nothing.
  def notify(event) do
    pid = Process.whereis(:probe_listener)
    record(pid != nil)
    send(pid, event)
  end

  def notify_is_pid(event) do
    pid = Process.whereis(:probe_listener)
    record(is_pid(pid))
    GenServer.cast(pid, event)
    :ok
  end

  defp record(alive), do: :persistent_term.put({__MODULE__, :alive}, alive)
end

defmodule Probe.R2.G10.WhereisRescueExit do
  # The lookup's nil is used in a call, which EXITS (:noproc) — a rescue
  # (error class) does not take it. The caller crashes whenever the
  # server is not registered.
  def ping do
    try do
      GenServer.call(Process.whereis(:probe_srv), :ping)
    rescue
      _ -> :down
    end
  end
end

defmodule S2c.Fail.LogWork do
  # Adversarial: work in Logger's own call arguments, a project call.
  def run(x) do
    try do
      :logger.warning("~p", [S2c.Fail.LogWork.store!(x)])
    catch
      _, _ -> :ok
    end
  end

  def store!(x), do: Map.fetch!(x, :k)

  # Adversarial: apply of log whose first argument is no level.
  def wal(mod, e) do
    try do
      mod.log(e, :sync)
    catch
      _, _ -> :ok
    end
  end

  # Negative: a pure argument.
  def fine(x) do
    try do
      :logger.info("~p", [inspect(x)])
    catch
      _, _ -> :ok
    end
  end
end

defmodule S2c.Fail.GuardApi do
  def stop(pid) when is_pid(pid), do: GenServer.stop(pid)
  def ping(:a), do: GenServer.call(:a, :ping)
  def ping(:b), do: GenServer.call(:b, :ping)
  # Negative: one clause, no guard.
  def plain(p), do: GenServer.call(p, :ping)
end

defmodule S2c.Fail.GuardCaller do
  def a(p),
    do:
      (try do
         S2c.Fail.GuardApi.stop(p)
       catch
         _, _ -> :ok
       end)

  def b(r),
    do:
      (try do
         S2c.Fail.GuardApi.ping(r)
       catch
         _, _ -> :ok
       end)

  def c(p),
    do:
      (try do
         S2c.Fail.GuardApi.plain(p)
       catch
         _, _ -> :ok
       end)
end

defmodule S2c.Fail.Whereis do
  # Adversarial: rescue around a call on the looked-up name, exit class.
  def stop do
    try do
      GenServer.stop(Process.whereis(:s2c_srv))
    rescue
      _ -> :ok
    end
  end

  # Adversarial: exit caught, but the use is a send (badarg).
  def poke do
    try do
      send(Process.whereis(:s2c_srv), :poke)
    catch
      :exit, _ -> :ok
    end
  end

  # Adversarial: boolean stored, pid used.
  def tell(m) do
    pid = Process.whereis(:s2c_srv)
    :persistent_term.put(:s2c_up, is_pid(pid))
    send(pid, m)
  end

  # Negative: boolean branched on.
  def safe(m) do
    pid = Process.whereis(:s2c_srv)
    if pid != nil, do: send(pid, m)
  end
end

defmodule S2c.Fail.Erpc do
  # Adversarial: erpc with only error class kept.
  def a(n),
    do:
      (try do
         :erpc.call(n, S2c.Fail.Erpc, :f, [])
       rescue
         _ -> nil
       end)

  def b(n),
    do:
      (try do
         :erpc.call(n, S2c.Fail.Erpc, :f, [], 1000)
       catch
         _, _ -> nil
       end)

  def f, do: Map.fetch!(Process.get(:s2c_map, %{}), :x)
  # Adversarial: Supervisor.start_child with a map child spec still builds it in the caller.
  def c(s),
    do:
      (try do
         Supervisor.start_child(s, %{id: 1, start: {S2c.Fail.Erpc, :f, []}})
       catch
         _, _ -> nil
       end)
end
