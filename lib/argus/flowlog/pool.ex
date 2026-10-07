defmodule Argus.FlowLog.Pool do
  @moduledoc """
  The engines a VM keeps between solves, so that a solve over facts
  that changed little costs little: the engine that solved the program
  last still holds its dataflow, and takes only the rows that moved.

  An engine is kept per lineage: a project (the graph's `program` key),
  a store, and a Datalog program's digest. Two databases over the same
  project in one VM (an editor session's, a recompile's) share it; they
  serialize on it, and each commit names every input that differs from
  what the engine holds, so neither can see the other's facts.

  Engines are processes linked to this one, which starts on first use
  (`checkout/3`): argus has no application to supervise it, and runs
  inside Mix tasks, an escript and other projects' VMs alike. When this
  process stops, every engine stops with it, and every engine's OS
  process with its port.

  A VM keeps at most `:max_engines` engines (default 32, or
  `ARGUS_FLOWLOG_ENGINES`); starting one more stops the least recently
  used. An engine unused for `:idle_ms` (default ten minutes, or
  `ARGUS_FLOWLOG_IDLE_MS`) stops: a VM about to exit loses nothing, and
  a long-lived one (an editor's) does not hold memory it stopped using.
  Neither stops an engine in use (`with_engine/3`): a commit may run
  longer than the idle time, and the pool may briefly hold more than
  its cap.
  """

  use GenServer

  alias Argus.FlowLog.Engine

  @default_max 32
  @default_idle_ms 600_000

  @typedoc "What an engine is kept by."
  @type key :: term()

  @doc """
  Runs `fun` with the engine kept for `key`, started with `start` (a
  function returning `Engine.start_link/1`'s options, or an error) when
  none is.

  The engine is in use until `fun` returns, or its caller exits. When
  `fun` returns an error the engine's state is unknown, and it stops:
  the next use of `key` starts another.
  """
  @spec with_engine(
          key(),
          (-> {:ok, keyword()} | {:error, term()}),
          (Engine.t() -> {:ok, result} | {:error, term()})
        ) :: {:ok, result} | {:error, term()}
        when result: var
  def with_engine(key, start, fun) do
    pool = ensure_started()

    with {:ok, pid, lease} <- GenServer.call(pool, {:checkout, key, start, self()}, :infinity) do
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

  @doc "Stops the engine kept for `key`, if any."
  @spec discard(key()) :: :ok
  def discard(key) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:discard, key}, :infinity)
    end
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
       max: env_int("ARGUS_FLOWLOG_ENGINES", @default_max),
       idle_ms: env_int("ARGUS_FLOWLOG_IDLE_MS", @default_idle_ms)
     }}
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @impl GenServer
  def handle_call({:checkout, key, start, user}, _from, state) do
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
        case start_engine(drop(state, key), key, start) do
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

  def handle_call({:discard, key}, _from, state), do: {:reply, :ok, stop_engine(state, key)}

  def handle_call(:close_all, _from, state) do
    {:reply, :ok, Enum.reduce(Map.keys(state.engines), state, &stop_engine(&2, &1))}
  end

  def handle_call(:keys, _from, state), do: {:reply, Map.keys(state.engines), state}

  @impl GenServer
  def handle_info({:idle, key, ref}, state) do
    case Map.fetch(state.engines, key) do
      {:ok, %{timer: {_, ^ref}, users: users}} when map_size(users) == 0 ->
        {:noreply, stop_engine(state, key)}

      _ ->
        {:noreply, state}
    end
  end

  # A user that exits holding its lease left the engine mid-commit.
  def handle_info({:DOWN, lease, :process, _pid, _reason}, state) do
    {:noreply, release(state, lease, :discard)}
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
  defp start_engine(state, key, start) do
    with {:ok, opts} <- start.(),
         {:ok, pid} <- Engine.start_link(opts) do
      state = evict(state)
      entry = %{pid: pid, used: System.monotonic_time(), timer: nil, users: %{}}
      state = %{state | by_pid: Map.put(state.by_pid, pid, key)}
      state = touch(state, key, entry)
      {:ok, state.engines[key], state}
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
          {:ok, %{pid: ^pid} = entry} when outcome == :keep ->
            touch(state, key, %{entry | users: Map.delete(entry.users, lease)})

          {:ok, %{pid: ^pid}} ->
            stop_engine(state, key)

          _ ->
            state
        end
    end
  end

  defp touch(state, key, entry) do
    if timer = entry.timer, do: Process.cancel_timer(elem(timer, 0))
    ref = make_ref()
    timer = Process.send_after(self(), {:idle, key, ref}, state.idle_ms)
    entry = %{entry | used: System.monotonic_time(), timer: {timer, ref}}
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
      {:ok, %{pid: pid} = entry} ->
        if timer = entry.timer, do: Process.cancel_timer(elem(timer, 0))
        Process.unlink(pid)
        Engine.stop(pid)
        drop(state, key)

      :error ->
        state
    end
  end

  defp drop(state, key) do
    case Map.pop(state.engines, key) do
      {nil, _} -> state
      {%{pid: pid}, engines} -> %{state | engines: engines, by_pid: Map.delete(state.by_pid, pid)}
    end
  end
end
