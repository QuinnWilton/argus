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
