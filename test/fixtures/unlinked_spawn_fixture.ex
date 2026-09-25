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
    # peer's start_orphan_supervision: proc_lib:start waits for the
    # process's init_ack and returns a failed start as a value, and the
    # process reports its own crash. Not a bare spawn.
    :proc_lib.start(__MODULE__, :init_it, [self()])
  end

  def init_it(parent), do: :proc_lib.init_ack(parent, {:ok, self()})
end
