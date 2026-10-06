defmodule Argus.Test.Fixtures.UnlinkedSpawner do
  @moduledoc false

  def spawn_unlinked do
    # Bare spawn — no link, no monitor. Orphan process.
    spawn(fn -> :ok end)
  end

  def spawn_linked do
    # spawn_link — linked to caller. Not an orphan.
    spawn_link(fn -> :ok end)
  end

  def spawn_monitored do
    # spawn_monitor — monitored by caller. Not an orphan.
    spawn_monitor(fn -> :ok end)
  end

  def start_synchronously do
    # proc_lib:start waits for the process's init_ack and returns a failed
    # start as a value, and this process's life ends at the ack: the start
    # the caller waited on is all of it.
    :proc_lib.start(__MODULE__, :init_it, [self()])
  end

  def init_it(parent), do: :proc_lib.init_ack(parent, {:ok, self()})
end

defmodule Argus.Test.Fixtures.ProcLibWorker do
  @moduledoc """
  A worker started with proc_lib:start that loops after its ack: the ack
  covers the start, and nothing watches the worker after it, as nothing
  would watch the same worker proc_lib:spawn started.
  """

  def start_worker, do: :proc_lib.start(__MODULE__, :init_worker, [self()])

  def init_worker(parent) do
    :proc_lib.init_ack(parent, {:ok, self()})
    worker_loop()
  end

  defp worker_loop do
    receive do
      {:work, from} ->
        send(from, :done)
        worker_loop()
    end
  end
end

defmodule Argus.Test.Fixtures.SpawnsMapped do
  @moduledoc """
  Spawns an Enum.map or comprehension closure makes, watched afterwards by
  the enclosing function on each pid: value flow follows the pids out of
  the closure, through the list, into the monitor or link, a captured one
  included. Only the spawns nothing watches are unwatched.
  """

  def monitored_capture(n) do
    pids = Enum.map(1..n, fn _ -> spawn(fn -> loop() end) end)
    Enum.each(pids, &Process.monitor/1)
    pids
  end

  def monitored_closure(n) do
    pids = Enum.map(1..n, fn _ -> spawn(fn -> loop() end) end)
    Enum.each(pids, fn pid -> Process.monitor(pid) end)
    pids
  end

  def linked_comprehension(n) do
    pids = for _ <- 1..n, _ <- [1, 2], do: spawn(fn -> loop() end)
    Enum.each(pids, &Process.link/1)
    pids
  end

  def unwatched_mapped(n) do
    pids = Enum.map(1..n, fn _ -> spawn(fn -> loop() end) end)
    Enum.each(pids, fn pid -> send(pid, :go) end)
    pids
  end

  defp loop, do: receive(do: (_ -> loop()))
end
