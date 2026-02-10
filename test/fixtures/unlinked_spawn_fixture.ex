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
end
