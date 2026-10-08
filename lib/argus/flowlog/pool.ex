defmodule Argus.FlowLog.Pool do
  @moduledoc """
  The engines a VM keeps between solves, so that a solve over facts
  that changed little costs little: the engine that solved the program
  last still holds its dataflow, and takes only the rows that moved.

  An engine is kept by a key (the graph's: a project, a program and its
  digest) for an owner: a process whose life the engine's is part of,
  the graph's database (`Roux.Database`'s supervisor). When the owner
  exits, every engine kept for it stops, mid-commit or not: an editor's
  session keeps its engines for as long as it is open, and a test's stop
  with the test.

  Engines are processes linked to this one, which starts on first use
  (`with_engine/4`): argus has no application to supervise it, and runs
  inside Mix tasks, an escript and other projects' VMs alike. When this
  process stops, every engine stops with it, and every engine's OS
  process with its port.

  A session that ends with its run (a compile, `mix argus`, an escript)
  solves each program once, so it keeps none (`keep/2`): its engines
  stop as each solve returns, rather than every one of the run's being
  held until it ends.

  A VM keeps at most `:max_engines` engines (default 32, or
  `ARGUS_FLOWLOG_ENGINES`); starting one more stops the least recently
  used one that is not in use, so an engine in use is never stopped for
  room, and the pool may briefly hold more than its cap.
  """

  use GenServer

  alias Argus.FlowLog.Engine

  @default_max 32

  @typedoc "What an engine is kept by."
  @type key :: term()

  @doc """
  Runs `fun` with the engine kept for `key`, started with `start` (a
  function returning `Engine.start_link/1`'s options, or an error) when
  none is. An engine started here stops when `owner` exits.

  The engine is in use until `fun` returns, or its caller exits. When
  `fun` returns an error the engine's state is unknown, and it stops:
  the next use of `key` starts another.
  """
  @spec with_engine(
          key(),
          pid(),
          (-> {:ok, keyword()} | {:error, term()}),
          (Engine.t() -> {:ok, result} | {:error, term()})
        ) :: {:ok, result} | {:error, term()}
        when result: var
  def with_engine(key, owner, start, fun) when is_pid(owner) do
    pool = ensure_started()
    checkout = {:checkout, key, owner, start, self()}

    with {:ok, pid, lease} <- GenServer.call(pool, checkout, :infinity) do
      result =
        try do
          fun.(pid)
        catch
          kind, reason ->
            :ok = GenServer.call(pool, {:checkin, lease, :discard}, :infinity)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      outcome = if match?({:ok, _}, result), do: :keep, else: :discard
      :ok = GenServer.call(pool, {:checkin, lease, outcome}, :infinity)
      result
    end
  end

  @doc """
  Whether the engines `owner` uses are kept once a solve returns them
  (by default, they are). An owner that keeps none starts an engine for
  each solve, and it stops as the solve returns: what a session that
  solves each program once wants, its run's engines never all alive at
  once. The setting lasts as long as `owner`.
  """
  @spec keep(pid(), boolean()) :: :ok
  def keep(owner, keep?) when is_pid(owner) and is_boolean(keep?) do
    GenServer.call(ensure_started(), {:keep, owner, keep?}, :infinity)
  end

  @doc "Stops every engine this VM keeps."
  @spec close_all() :: :ok
  def close_all do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :close_all, :infinity)
    end
  end

  @doc "The keys of the engines this VM keeps."
  @spec keys() :: [key()]
  def keys do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :keys, :infinity)
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init([]) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       engines: %{},
       by_pid: %{},
       # A lease (the monitor of the process using an engine) to its key.
       leases: %{},
       # An owner's monitor to its pid and the keys of its engines.
       owners: %{},
       # The owners that keep no engine, each to its monitor.
       unkept: %{},
       max: env_int("ARGUS_FLOWLOG_ENGINES", @default_max)
     }}
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @impl GenServer
  def handle_call({:checkout, key, owner, start, user}, _from, state) do
    found =
      case Map.fetch(state.engines, key) do
        {:ok, %{pid: pid}} = found -> if Process.alive?(pid), do: found, else: :error
        :error -> :error
      end

    case found do
      {:ok, entry} ->
        {lease, state} = lease(state, key, entry, user)
        {:reply, {:ok, entry.pid, lease}, state}

      :error ->
        case start_engine(drop(state, key), key, owner, start) do
          {:ok, entry, state} ->
            {lease, state} = lease(state, key, entry, user)
            {:reply, {:ok, entry.pid, lease}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:checkin, lease, outcome}, _from, state) do
    Process.demonitor(lease, [:flush])
    {:reply, :ok, release(state, lease, outcome)}
  end

  def handle_call({:keep, owner, false}, _from, state) do
    case state.unkept do
      %{^owner => _} -> {:reply, :ok, state}
      unkept -> {:reply, :ok, %{state | unkept: Map.put(unkept, owner, Process.monitor(owner))}}
    end
  end

  def handle_call({:keep, owner, true}, _from, state) do
    case Map.pop(state.unkept, owner) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, unkept} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | unkept: unkept}}
    end
  end

  def handle_call(:close_all, _from, state) do
    {:reply, :ok, Enum.reduce(Map.keys(state.engines), state, &stop_engine(&2, &1))}
  end

  def handle_call(:keys, _from, state), do: {:reply, Map.keys(state.engines), state}

  # An owner that exits takes its engines with it. A user that exits
  # holding its lease left the engine mid-commit.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.owners, ref) do
      {{_owner, keys}, owners} ->
        {:noreply, Enum.reduce(keys, %{state | owners: owners}, &stop_engine(&2, &1))}

      {nil, _} ->
        case Enum.find(state.unkept, fn {_owner, monitor} -> monitor == ref end) do
          {owner, _} -> {:noreply, %{state | unkept: Map.delete(state.unkept, owner)}}
          nil -> {:noreply, release(state, ref, :discard)}
        end
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case Map.fetch(state.by_pid, pid) do
      {:ok, key} -> {:noreply, drop(state, key)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Started from this process, so the engine is linked to it. A build
  # (the engine binary) happens in `start`, before this call: the pool
  # never waits on Cargo.
  defp start_engine(state, key, owner, start) do
    with {:ok, opts} <- start.(),
         {:ok, pid} <- Engine.start_link(opts) do
      state = state |> evict() |> own(owner, key)
      entry = %{pid: pid, owner: owner, used: System.monotonic_time(), users: %{}}
      state = %{state | by_pid: Map.put(state.by_pid, pid, key)}
      state = touch(state, key, entry)
      {:ok, state.engines[key], state}
    end
  end

  # The owner's monitor, taken with its first engine.
  defp own(state, owner, key) do
    case Enum.find(state.owners, fn {_ref, {pid, _keys}} -> pid == owner end) do
      {ref, {^owner, keys}} ->
        %{state | owners: Map.put(state.owners, ref, {owner, MapSet.put(keys, key)})}

      nil ->
        ref = Process.monitor(owner)
        %{state | owners: Map.put(state.owners, ref, {owner, MapSet.new([key])})}
    end
  end

  defp lease(state, key, entry, user) do
    lease = Process.monitor(user)
    entry = %{entry | users: Map.put(entry.users, lease, true)}

    {lease, %{touch(state, key, entry) | leases: Map.put(state.leases, lease, {key, entry.pid})}}
  end

  # The lease's engine is unused once more; one that failed stops. An
  # engine replaced since (stopped, restarted) is left alone.
  defp release(state, lease, outcome) do
    case Map.pop(state.leases, lease) do
      {nil, _} ->
        state

      {{key, pid}, leases} ->
        state = %{state | leases: leases}

        case Map.fetch(state.engines, key) do
          {:ok, %{pid: ^pid, owner: owner} = entry}
          when outcome == :keep and not is_map_key(state.unkept, owner) ->
            touch(state, key, %{entry | users: Map.delete(entry.users, lease)})

          {:ok, %{pid: ^pid}} ->
            stop_engine(state, key)

          _ ->
            state
        end
    end
  end

  defp touch(state, key, entry) do
    entry = %{entry | used: System.monotonic_time()}
    %{state | engines: Map.put(state.engines, key, entry)}
  end

  # Room for one more engine: the least recently used unused ones stop
  # until the pool is under its cap, or every engine left is in use.
  defp evict(state) do
    idle = Enum.filter(state.engines, fn {_key, entry} -> map_size(entry.users) == 0 end)

    if map_size(state.engines) < state.max or idle == [] do
      state
    else
      {key, _} = Enum.min_by(idle, fn {_key, entry} -> entry.used end)
      state |> stop_engine(key) |> evict()
    end
  end

  defp stop_engine(state, key) do
    case Map.fetch(state.engines, key) do
      {:ok, %{pid: pid}} ->
        Process.unlink(pid)
        Engine.stop(pid)
        drop(state, key)

      :error ->
        state
    end
  end

  # An owner left with no engine is no longer watched.
  defp drop(state, key) do
    case Map.pop(state.engines, key) do
      {nil, _} ->
        state

      {%{pid: pid, owner: owner}, engines} ->
        %{state | engines: engines, by_pid: Map.delete(state.by_pid, pid)}
        |> disown(owner, key)
    end
  end

  defp disown(state, owner, key) do
    case Enum.find(state.owners, fn {_ref, {pid, _keys}} -> pid == owner end) do
      {ref, {^owner, keys}} ->
        keys = MapSet.delete(keys, key)

        if MapSet.size(keys) == 0 do
          Process.demonitor(ref, [:flush])
          %{state | owners: Map.delete(state.owners, ref)}
        else
          %{state | owners: Map.put(state.owners, ref, {owner, keys})}
        end

      nil ->
        state
    end
  end
end
