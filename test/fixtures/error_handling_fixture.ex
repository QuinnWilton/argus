defmodule Argus.Test.Fixtures.BareRescue do
  @moduledoc false

  # Uses try/catch which catches all exception classes without filtering.
  # Unlike rescue (which only catches errors), catch catches everything.
  def swallow_all(f) do
    try do
      f.()
    catch
      _, _ -> :ok
    end
  end
end

defmodule Argus.Test.Fixtures.BoundaryRescue do
  @moduledoc """
  Catch-alls around what another process, a node or a name decides: a
  send, a call into a server, a supervisor query, a named table that may
  exist. What they take is a dead peer or a taken name, not a bug here.
  """

  def notify(pid, msg) do
    try do
      send(pid, {self(), msg})
      :ok
    catch
      _, _ -> :ok
    end
  end

  def safe_count(sup) do
    try do
      Supervisor.count_children(sup)
    catch
      _, _ -> %{}
    end
  end

  def ask(server) do
    try do
      GenServer.call(server, :ping, 1_000)
    catch
      _, _ -> :down
    end
  end

  def ensure_table do
    try do
      :ets.new(:boundary_rescue, [:named_table, :public])
    catch
      _, _ -> :boundary_rescue
    end
  end

  # ra's logging macro: the log line, its arguments built on its own
  # lines, dispatched to a logger module the program configures, and a
  # handler failure never taking the server down.
  def note_members(cluster) do
    try do
      logger_mod().log(:debug, "members: ~p", [Map.keys(cluster)], %{domain: [:app]})
    catch
      _, _ -> :ok
    end

    :ok
  end

  def warn(reason) do
    try do
      :logger.warning("giving up: ~p", [reason])
    catch
      _, _ -> :ok
    end
  end

  def logger_mod, do: :persistent_term.get(:app_logger, :logger)

  # hackney's `try hackney_conn:stop(Pid) catch _:_ -> ok end`: the
  # client API is the boundary one hop away.
  def close(conn) do
    try do
      Argus.Test.Fixtures.BoundaryClient.stop(conn)
    catch
      _, _ -> :ok
    end
  end
end

defmodule Argus.Test.Fixtures.BoundaryClient do
  @moduledoc "A client API that is nothing but a call into the server."

  def stop(pid), do: :gen_statem.stop(pid)
  def status(pid), do: GenServer.call(pid, :status, 1_000)

  # Its reply matched: a bug in the match is the caller's, not the peer's.
  def count(pid) do
    {:ok, n} = GenServer.call(pid, :count, 1_000)
    n
  end
end

defmodule Argus.Test.Fixtures.LogicRescue do
  @moduledoc """
  The twins of BoundaryRescue that guard the program's own logic too: a
  match on the reply, arithmetic, a call into a helper. A catch-all there
  swallows a bug.
  """

  def ask_and_match(server) do
    try do
      {:ok, n} = GenServer.call(server, :count, 1_000)
      n + 1
    catch
      _, _ -> 0
    end
  end

  def notify_decoded(pid, bin) do
    try do
      send(pid, decode(bin))
      :ok
    catch
      _, _ -> :ok
    end
  end

  # A log line beside the work: the work's failure is swallowed too.
  def apply_and_log(state) do
    try do
      apply_entry(state)
      :logger.info("applied")
    catch
      _, _ -> :ok
    end
  end

  # The work's result is logged, but the work is its own statement.
  def apply_and_log_result(state) do
    try do
      result = apply_entry(state)
      :logger.info("applied: ~p", [result])
    catch
      _, _ -> :ok
    end
  end

  def apply_entry(state), do: Map.fetch!(state, :entry) + 1

  # A client API whose reply it matches: a bug there is swallowed too.
  def safe_count(pid) do
    try do
      Argus.Test.Fixtures.BoundaryClient.count(pid)
    catch
      _, _ -> 0
    end
  end

  defp decode(bin), do: :erlang.binary_to_term(bin, [:safe])
end

defmodule Argus.Test.Fixtures.FilteredRescue do
  @moduledoc false

  # rescue _ -> adds a class test for :error and re-raises non-error.
  def handle_specific(f) do
    try do
      f.()
    rescue
      _ -> :caught
    end
  end
end

defmodule Argus.Test.Fixtures.ReifyingRescue do
  @moduledoc false

  # Catches all classes but reifies the exception into a returned value —
  # the caller sees the error, nothing is swallowed. Must NOT be flagged.
  def to_result(f) do
    try do
      f.()
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  def to_map(f) do
    try do
      f.()
    catch
      kind, reason -> %{kind: kind, reason: reason}
    end
  end

  def to_closure(f) do
    try do
      f.()
    catch
      _, reason -> fn -> reason end
    end
  end

  def to_class(f) do
    try do
      f.()
    catch
      kind, _ -> kind
    end
  end
end

defmodule Argus.Test.Fixtures.ReraisingRescue do
  @moduledoc false

  # Catches all classes, runs cleanup, then re-raises with the original
  # stacktrace — compiles to the raw_raise opcode. Must NOT be flagged.
  def cleanup_and_reraise(f, cleanup) do
    try do
      f.()
    catch
      kind, reason ->
        cleanup.()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end

defmodule Argus.Test.Fixtures.TrapExitModule do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(_, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapScopedModule do
  @moduledoc false

  # Traps around one call, then clears the flag: a literal false.
  def with_trap(fun) do
    Process.flag(:trap_exit, true)
    result = fun.()
    Process.flag(:trap_exit, false)
    result
  end

  # Restores whatever the flag was: a computed value, neither a set nor a
  # clear.
  def restore(old), do: Process.flag(:trap_exit, old)
end

defmodule Argus.Test.Fixtures.ExitCaller do
  @moduledoc false

  def kill(pid), do: Process.exit(pid, :kill)
  def exit_self, do: :erlang.exit(:normal)
end

defmodule Argus.Test.Fixtures.IgnoredResultModule do
  @moduledoc false

  def ignored_start do
    GenServer.start_link(Argus.Test.Fixtures.PlainModule, [])
    :ok
  end

  def checked_start do
    case GenServer.start_link(Argus.Test.Fixtures.PlainModule, []) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "failed: #{inspect(reason)}"
    end
  end

  # Enum.each drops what its fun answers: each start's result reaches no one.
  def each_ignored_start(names), do: Enum.each(names, fn n -> Agent.start_link(fn -> n end) end)

  # Enum.map keeps the answers: the caller has every start's result.
  def mapped_checked_start(names), do: Enum.map(names, fn n -> Agent.start_link(fn -> n end) end)
end

defmodule Argus.Test.Fixtures.RawTrapExit do
  @moduledoc false

  # Hand-rolled :gen_server (no `use GenServer`): traps exits but defines
  # no handle_info, so {:EXIT, ...} messages crash the server. `use
  # GenServer` modules always compile in a default handle_info, which is
  # why this rule can only fire for raw behaviour modules.
  @behaviour :gen_server

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsForItsCaller do
  @moduledoc """
  grpc's Mint adapter: `connect/2` traps exits in whatever process calls
  it (the connection process, through a variable). This module runs no
  process, so no gen_server of its own misses a handle_info/2.
  """

  def connect(host, opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{host: host, opts: opts}}
  end
end

defmodule Argus.Test.Fixtures.ExitingServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  # Process.exit inside a callback bypasses OTP shutdown protocol.
  @impl true
  def handle_cast({:kill, pid}, state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.SharedKill do
  @moduledoc """
  One exit call, in a helper three callbacks run (Exq's Redis failover
  kill): one finding, at the helper's call. A second exit, made in a
  callback of its own, is a second finding.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:query, _from, state), do: {:reply, reconnect(state), state}

  @impl true
  def handle_cast(:query, state), do: {:noreply, reconnect(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, reconnect(state)}

  def handle_info({:stop_worker, pid}, state) do
    Process.exit(pid, :shutdown)
    {:noreply, state}
  end

  defp reconnect(%{conn: conn} = state) do
    Process.exit(conn, :kill)
    state
  end
end

defmodule Argus.Test.Fixtures.StatemTrapExit do
  @moduledoc false
  @behaviour :gen_statem

  def callback_mode, do: :state_functions

  # Traps exits and has no handle_info — but delivers {:EXIT, ...} to its
  # state functions, which it handles. Must NOT be flagged
  # trap_exit_without_handler.
  def init(_args) do
    Process.flag(:trap_exit, true)
    {:ok, :idle, %{}}
  end

  def idle(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}
  def idle(_type, _content, data), do: {:keep_state, data}
end

defmodule Argus.Test.Fixtures.SelfCrashCallback do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  # exit/1 raises an exit in THIS process (let-it-crash on an impossible
  # state) — supervision-visible, not an imperative kill of another
  # process. Must NOT be flagged exit_in_callback.
  @impl true
  def handle_call(:bad, _from, _state) do
    exit(:impossible_state)
  end
end

defmodule Argus.Test.Fixtures.TrapsWithoutExitClause do
  @moduledoc """
  Traps exits and has a handle_info/2 — so it passes the "no handler"
  check — but no clause accepts {:EXIT, ...}. Bandit's HTTP/1 handler.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.SpawnsATrapper do
  @moduledoc """
  The twin of TrapsWithoutExitClause whose trap_exit is set in a fun it
  spawns: the middleman traps, not the server, and the server's
  handle_info/2 is never handed an {:EXIT, ...}.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(parent, :ready)
    end)

    {:ok, state}
  end

  @impl true
  def handle_info(:ready, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsWithExitClause do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.MonitorsWithoutCatchall do
  @moduledoc """
  Monitors each watcher and takes the :DOWN of the one it watches now,
  the ref pinned to the state: a :DOWN of an earlier one, arriving after
  the next :watch replaced it, crashes it.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{ref: nil}}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    {:reply, ref, %{state | ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state),
    do: {:noreply, %{state | ref: nil}}
end

defmodule Argus.Test.Fixtures.MonitorsTakingEveryDown do
  @moduledoc """
  Monitors callers and takes every process monitor's :DOWN, whatever
  its ref: nothing the runtime sends it lacks a clause (eventstore's
  AdvisoryLocks, FLAME's Pool).
  """
  use GenServer

  defstruct watched: %{}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    {:reply, ref, %{state | watched: Map.put(state.watched, ref, pid)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{} = state),
    do: {:noreply, %{state | watched: Map.delete(state.watched, ref)}}
end

defmodule Argus.Test.Fixtures.MonitorsDownWhenActive do
  @moduledoc """
  Takes a :DOWN only while its state says it is active: in any other
  mode the same :DOWN crashes it.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{mode: :active}}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    _ = Process.monitor(pid)
    {:reply, :ok, state}
  end

  def handle_call(:pause, _from, state), do: {:reply, :ok, %{state | mode: :paused}}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{mode: :active} = state),
    do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsTakingEveryExit do
  @moduledoc """
  Traps exits and monitors, and takes every :EXIT and every :DOWN
  (Lightning's RuntimeManager, eventstore's Subscription).
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    _ = Process.monitor(pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsTakingNormalExits do
  @moduledoc """
  Traps exits and takes every :DOWN, but only a :normal :EXIT: an
  abnormal exit of a linked process crashes it by a FunctionClauseError.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    _ = Process.monitor(pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.PartialInfoServer do
  @moduledoc false
  # Handles one message and nothing else; monitors nothing, traps nothing —
  # but arms a timer whose message is computed whole (read from the
  # state), which the one clause cannot be shown to take.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.send_after(self(), Map.get(state, :message), 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _at}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TaggedTimerServer do
  @moduledoc false
  # Arms a timer whose message it builds around a literal tag,
  # `{:tick, at}`, and has the clause for that tag: the late message is
  # one it takes.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.send_after(self(), {:tick, System.monotonic_time()}, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, _at}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TaskTimerPartialInfoServer do
  @moduledoc false
  # The same computed timer, armed by a task the server starts: it fires
  # into the task's mailbox, not the server's.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:poll, state) do
    Task.start(fn ->
      Process.send_after(self(), Map.get(state, :message), 1_000)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, _at}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.HandledTimerServer do
  @moduledoc false
  # A janitor: arms a bare :purge for itself and has the :purge clause.
  # Its late message is one it takes; nothing else writes its mailbox.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.send_after(self(), :purge, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:purge, state) do
    Process.send_after(self(), :purge, 1_000)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.TotalInfoServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.PartialInfoStage do
  @moduledoc false
  # A producer stage with a partial handle_info: the shape of gen_stage#238.
  use GenStage

  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 1_000)
    {:producer, state}
  end

  @impl true
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl true
  def handle_info(:refill, state), do: {:noreply, [], state}
end

defmodule Argus.Test.Fixtures.QuietPartialInfoServer do
  @moduledoc false
  # A partial handle_info with nothing in reach that writes the mailbox:
  # a style note, not a finding.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.AppliesPartialInfoServer do
  @moduledoc false
  # No timer, no task — but it runs a caller-supplied function, which may
  # leave anything in this mailbox.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(fun), do: {:ok, fun}

  @impl true
  def handle_cast(:run, fun) do
    fun.()
    {:noreply, fun}
  end

  @impl true
  def handle_info(:tick, fun), do: {:noreply, fun}
end

defmodule Argus.Test.Fixtures.SelfSendPartialInfoServer do
  @moduledoc false
  # A start-up message the process sends itself, re-sent by every restart
  # (cachex#314): `send/2` compiles to a call to :erlang.send/2.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    send(self(), :warm)
    {:ok, state}
  end

  @impl true
  def handle_info(:warm, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.ClientMonitorsServer do
  @moduledoc """
  The only monitor is in a client function, which runs in the caller:
  the server itself receives no :DOWN, and its partial handle_info is no
  runtime-written mailbox.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  def await_up, do: Process.monitor(Process.whereis(__MODULE__))

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:ping, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.InlineOrTaskPartialInfoServer do
  @moduledoc false
  # The computed timer is armed by a fun the server runs in a task when
  # the pool is up, and inline otherwise: inline, it fires into the
  # server's mailbox.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:poll, state) do
    work = fn -> Process.send_after(self(), Map.get(state, :message), 1_000) end

    case Process.whereis(:pollers) do
      nil -> work.()
      sup -> Task.Supervisor.start_child(sup, work)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, _at}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.ReturnsCall do
  @moduledoc false
  # `arm/1` returns what the local helper returns; `log/1` calls it and
  # returns something else.
  def arm(ms), do: schedule(ms)

  def log(ms) do
    schedule(ms)
    :ok
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end

defmodule Argus.Test.Fixtures.TrapHelper do
  @moduledoc """
  A plain module whose function sets trap_exit for whoever calls it: the
  flag is the calling process's, never this module's (it runs no
  process).
  """
  def enable do
    Process.flag(:trap_exit, true)
    :ok
  end
end

defmodule Argus.Test.Fixtures.TrapsThroughHelper do
  @moduledoc """
  A server whose init/1 traps exits through TrapHelper.enable/0 and whose
  handle_info/2 has no {:EXIT, ...} clause: the server is the process
  that traps (postgrex's connect/1 trapping inside DBConnection's
  connection process, M2-17).
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    :ok = Argus.Test.Fixtures.TrapHelper.enable()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.CleansUpThroughHelperTrap do
  @moduledoc """
  A server whose trap is set by a helper it calls in init/1 and whose
  terminate/2 cleans up: it traps, so a supervisor's shutdown runs its
  terminate/2.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(path) do
    :ok = Argus.Test.Fixtures.TrapHelper.enable()
    {:ok, File.open!(path, [:write])}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, file), do: {:noreply, file}

  @impl true
  def terminate(_reason, file), do: File.close(file)
end

defmodule Argus.Test.Fixtures.CleansUpEnteringLoop do
  @moduledoc """
  A server started as ranch protocols are: a proc_lib start runs init/1,
  which sets trap_exit and enters the gen_server loop itself. The
  process proc_lib starts is the server, so it traps, and a supervisor's
  shutdown runs terminate/2.
  """
  @behaviour :gen_server

  def start_link(path), do: {:ok, :proc_lib.spawn_link(__MODULE__, :init, [path])}

  @impl true
  def init(path) do
    Process.flag(:trap_exit, true)
    :gen_server.enter_loop(__MODULE__, [], path)
  end

  @impl true
  def handle_call(_request, _from, path), do: {:reply, :ok, path}

  @impl true
  def handle_cast(_request, path), do: {:noreply, path}

  @impl true
  def handle_info({:EXIT, _pid, _reason}, path), do: {:noreply, path}

  @impl true
  def terminate(_reason, path), do: File.write!(path, "final")
end

defmodule Argus.Test.Fixtures.LeaksBesideAnotherLoop do
  @moduledoc """
  A server that never traps exits, and also starts a process that traps
  and enters another module's loop (OtherLoop's). That trap is
  the other server's: this one's terminate/2 is still skipped on
  shutdown.
  """
  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, path)

  def start_other(state), do: {:ok, :proc_lib.spawn_link(__MODULE__, :run_other, [state])}

  def run_other(state) do
    Process.flag(:trap_exit, true)
    :gen_server.enter_loop(Argus.Test.Fixtures.OtherLoop, [], state)
  end

  @impl true
  def init(path), do: {:ok, path}

  @impl true
  def terminate(_reason, path), do: File.write!(path, "final")
end

defmodule Argus.Test.Fixtures.OtherLoop do
  @moduledoc "The server LeaksBesideAnotherLoop's process enters."
  @behaviour :gen_server

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(_request, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.LeaksEnteringLoop do
  @moduledoc """
  The twin of CleansUpEnteringLoop that never sets trap_exit: entering
  the loop is no trap, and a supervisor's shutdown skips terminate/2.
  """
  @behaviour :gen_server

  def start_link(path), do: {:ok, :proc_lib.spawn_link(__MODULE__, :init, [path])}

  @impl true
  def init(path), do: :gen_server.enter_loop(__MODULE__, [], path)

  @impl true
  def handle_call(_request, _from, path), do: {:reply, :ok, path}

  @impl true
  def handle_cast(_request, path), do: {:noreply, path}

  @impl true
  def terminate(_reason, path), do: File.write!(path, "final")
end

defmodule Argus.Test.Fixtures.CleansUpAfterScopedTrap do
  @moduledoc """
  A server whose init/1 traps exits only around a start, then clears the
  flag: the server does not trap, so a supervisor's shutdown kills it
  without running its terminate/2, and no {:EXIT, ...} arrives for its
  handle_info/2 to miss.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(path) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Path.dirname(path))
    Process.flag(:trap_exit, false)
    {:ok, path}
  end

  @impl true
  def handle_info(:tick, path), do: {:noreply, path}

  @impl true
  def terminate(_reason, path), do: File.write!(path, "final")
end

defmodule Argus.Test.Fixtures.CleansUpOnOptionTrap do
  @moduledoc """
  A server whose init/1 traps exits when an option says so: on that path
  a supervisor's shutdown runs its terminate/2, and a trap any path sets
  counts.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({path, opts}) do
    if Keyword.get(opts, :trap, false), do: Process.flag(:trap_exit, true)
    {:ok, path}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, path), do: {:noreply, path}

  @impl true
  def terminate(_reason, path), do: File.write!(path, "final")
end

# Probes of the retired "handle_info/2 has no catch-all" rule's runtime
# source (FP hunt round 3): each takes every process monitor's :DOWN or
# every :EXIT, and the runtime still writes it something no clause takes
# (a port monitor's :DOWN, node events, a port's output, a :DOWN reason
# its guard refuses), which unhandled_info names.

defmodule Argus.Test.Fixtures.MonitorsPortTakingProcessDowns do
  @moduledoc "Monitors a port: its :DOWN says :port, and only :process ones are taken."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(port), do: {:ok, %{port: port}}

  @impl true
  def handle_call(:watch, _from, state) do
    ref = :erlang.monitor(:port, state.port)
    {:reply, ref, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.MonitorsNodesTakingDowns do
  @moduledoc "Monitors nodes as well as processes: {:nodeup, n} has no clause."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    _ = Process.monitor(pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsOpeningPort do
  @moduledoc "Traps and opens a port: every :EXIT is taken, the port's output is not."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    port = Port.open({:spawn, "cat"}, [:binary])
    {:reply, :ok, Map.put(state, :port, port)}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
end

defmodule Argus.Test.Fixtures.MonitorsDownGuardedByReason do
  @moduledoc "Takes a :DOWN only when its reason is not :normal: a :normal one crashes it."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    _ = Process.monitor(pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) when reason != :normal,
    do: {:noreply, state}
end
