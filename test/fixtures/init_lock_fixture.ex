defmodule Argus.Test.Fixtures.InitLock do
  @moduledoc """
  The shapes the precision audit of startup's lock-during-init rule
  (2026-09-24) found it misjudging, one module each, beside the controls
  that must keep their verdict.

  What decides a finding: whether the `:global` lock keeps retrying
  until it is granted (retries), whether init/1 is on its stack when it
  runs (callbacks, tasks, starts) and which clause of a shared helper
  init/1 enters.
  """

  # ── Retries ─────────────────────────────────────────────────────────

  defmodule Bounded do
    @moduledoc """
    Three retries over the cluster: set_lock/3 gives up after at most
    1.75 s of backoff and returns false. Not a lock that waits until it
    is granted, but each try still asks every node in the list.
    """
    use GenServer

    def init(name) do
      _ = lock(name)
      {:ok, name}
    end

    def lock(name), do: :global.set_lock({name, self()}, [node() | Node.list()], 3)
  end

  defmodule BoundedLocal do
    @moduledoc """
    Three retries over `[node()]`: the fix the local finding's help
    recommends. Quiet.
    """
    use GenServer

    def init(name) do
      _ = :global.set_lock({name, self()}, [node()], 3)
      {:ok, name}
    end
  end

  defmodule DynamicRetries do
    @moduledoc """
    Retries forwarded from the options, defaulting to :infinity — the
    shape of Nebulex.Adapter.Transaction. The count is not in the
    bytecode, so the rule assumes :infinity, as it assumes the cluster
    for a node list it cannot read.
    """
    use GenServer

    def init(opts) do
      _ = acquire(opts[:name], Keyword.get(opts, :retries, :infinity))
      {:ok, opts}
    end

    def acquire(name, retries),
      do: :global.set_lock({name, self()}, [node() | Node.list()], retries)
  end

  defmodule NoRetries do
    @moduledoc "Retries 0 tries once and returns. Quiet."
    use GenServer

    def init(name) do
      _ = :global.set_lock({name, self()}, [node() | Node.list()], 0)
      {:ok, name}
    end
  end

  # ── Funs init/1 does not run ────────────────────────────────────────

  defmodule TelemetryHandler do
    @moduledoc """
    init/1 registers a handler; :telemetry runs it later, in whichever
    process emits the event. Quiet.
    """
    use GenServer

    def init(name) do
      :ok = :telemetry.attach(name, [:cluster, :changed], &__MODULE__.on_change/4, name)
      {:ok, name}
    end

    def on_change(_event, _measurements, _metadata, name),
      do: :global.trans({name, self()}, fn -> :ok end)
  end

  defmodule TelemetryClosure do
    @moduledoc "The same handler written inline. Quiet."
    use GenServer

    def init(name) do
      :ok =
        :telemetry.attach(
          name,
          [:cluster, :changed],
          fn _event, _measurements, _metadata, name ->
            :global.trans({name, self()}, fn -> :ok end)
          end,
          name
        )

      {:ok, name}
    end
  end

  defmodule StoredCallback do
    @moduledoc """
    init/1 builds a fun and keeps it in its state; handle_continue/2
    runs it after init/1 has returned. Quiet.
    """
    use GenServer

    def init(name) do
      relock = fn -> :global.set_lock({name, self()}) end
      {:ok, %{name: name, relock: relock}, {:continue, :lock}}
    end

    def handle_continue(:lock, state) do
      true = state.relock.()
      {:noreply, state}
    end
  end

  defmodule EachClosure do
    @moduledoc """
    Control: a closure handed to Enum.each runs on init/1's stack. Reported.
    """
    use GenServer

    def init(opts) do
      Enum.each(opts[:names], fn name -> :global.set_lock({name, self()}) end)
      {:ok, opts}
    end
  end

  # ── An unrelated process start ──────────────────────────────────────

  defmodule StartChildBeside do
    @moduledoc """
    A start_child of a spec from the options, beside an Enum.each whose
    closure takes the lock. The start is not handed the closure. Reported.
    """
    use GenServer

    def init(opts) do
      {:ok, _} = Supervisor.start_child(opts[:sup], opts[:spec])
      Enum.each(opts[:names], fn name -> :global.set_lock({name, self()}) end)
      {:ok, opts}
    end
  end

  defmodule WarmupBeside do
    @moduledoc """
    A task on a fun from the options, beside the same Enum.each. Reported.
    """
    use GenServer

    def init(opts) do
      {:ok, _} = Task.start_link(opts[:warmup])
      Enum.each(opts[:names], fn name -> :global.set_lock({name, self()}) end)
      {:ok, opts}
    end
  end

  defmodule SpecClosure do
    @moduledoc """
    Control: the closure is built into a child spec, and runs in the
    child. Quiet.
    """
    use GenServer

    def init(opts) do
      spec = %{
        id: :locker,
        start: {Task, :start_link, [fn -> :global.set_lock({:k, self()}) end]}
      }

      {:ok, _} = Supervisor.start_child(opts[:sup], spec)
      {:ok, opts}
    end
  end

  defmodule HelperStart do
    @moduledoc """
    Control: a helper spawns the fun it is handed, so the closure runs in
    the new process. Quiet.
    """
    use GenServer

    def init(name) do
      {:ok, _} = start_worker(fn -> :global.set_lock({name, self()}) end)
      {:ok, name}
    end

    def start_worker(fun), do: Task.start_link(fun)
  end

  defmodule SpawnedLock do
    @moduledoc "Control: a task init/1 does not wait for. Quiet."
    use GenServer

    def init(name) do
      {:ok, _} = Task.start_link(fn -> :global.set_lock({name, self()}) end)
      {:ok, name}
    end
  end

  # ── A task init/1 waits for ─────────────────────────────────────────

  defmodule AwaitedTask do
    @moduledoc "Task.async then Task.await: init/1 waits for the lock. Reported."
    use GenServer

    def init(name) do
      Task.async(fn -> :global.set_lock({name, self()}) end) |> Task.await(:infinity)
      {:ok, name}
    end
  end

  defmodule UnawaitedTask do
    @moduledoc """
    Control: Task.async whose result init/1 keeps in its state and awaits
    later, in handle_info. Quiet.
    """
    use GenServer

    def init(name) do
      task = Task.async(fn -> :global.set_lock({name, self()}) end)
      {:ok, %{name: name, task: task}}
    end

    def handle_info({ref, _}, %{task: %{ref: ref}} = state), do: {:noreply, state}
  end

  defmodule AwaitedFromClosures do
    @moduledoc """
    Tasks a two-generator comprehension starts, in closures, and init/1
    awaits: init/1 waits for the lock. Reported.
    """
    use GenServer

    def init(names) do
      tasks =
        for name <- names, n <- [1, 2], do: Task.async(fn -> :global.set_lock({name, n}) end)

      Task.await_many(tasks, :infinity)
      {:ok, names}
    end
  end

  defmodule AwaitedInHelper do
    @moduledoc "A task init/1 starts and a helper awaits: init/1 waits for the lock. Reported."
    use GenServer

    def init(name) do
      finish(Task.async(fn -> :global.set_lock({name, self()}) end))
      {:ok, name}
    end

    defp finish(task), do: Task.await(task, :infinity)
  end

  defmodule AwaitsAnotherTask do
    @moduledoc """
    Control: init/1 starts a locking task it keeps in its state and awaits
    a different one. Quiet: crediting any await would report it.
    """
    use GenServer

    def init(name) do
      locking = Task.async(fn -> :global.set_lock({name, self()}) end)
      Task.async(fn -> :ok end) |> Task.await()
      {:ok, %{name: name, task: locking}}
    end

    def handle_info({ref, _}, %{task: %{ref: ref}} = state), do: {:noreply, state}
  end

  # ── Which clause init/1 enters ──────────────────────────────────────

  defmodule SharedHelper do
    @moduledoc """
    init/1 and handle_continue/2 share sync/2, and only the :locked
    clause, which init/1 never enters, takes the lock. Quiet.
    """
    use GenServer

    def init(s), do: {:ok, sync(:boot, s), {:continue, :lock}}
    def handle_continue(:lock, s), do: {:noreply, sync(:locked, s)}

    def sync(:boot, s), do: s

    def sync(:locked, s) do
      true = :global.set_lock({:k, self()})
      s
    end
  end

  defmodule SharedHelperEntered do
    @moduledoc "Control: init/1 enters the :locked clause. Reported."
    use GenServer

    def init(s), do: {:ok, sync(:locked, s)}

    def sync(:boot, s), do: s

    def sync(:locked, s) do
      true = :global.set_lock({:k, self()})
      s
    end
  end
end
