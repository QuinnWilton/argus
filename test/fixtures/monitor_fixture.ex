defmodule Argus.Test.Fixtures.MonitorLeak do
  @moduledoc """
  Fixtures for the monitor-leak analysis.

  The timeout is the discriminator, so the pairs vary only that: `Leaks` and
  `Blocks` differ by an `after` clause, `Leaks` and `Flushes` by the
  `[:flush]` option.
  """

  defmodule Leaks do
    @moduledoc "The bug: the wait can end without the message, monitor stays live."
    def wait(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
      after
        1000 -> :timeout
      end
    end
  end

  defmodule Flushes do
    @moduledoc "Same wait, but the monitor is cancelled and the mailbox cleared."
    def wait(pid) do
      ref = Process.monitor(pid)

      result =
        receive do
          {:DOWN, ^ref, :process, _, _} -> :down
        after
          1000 -> :timeout
        end

      Process.demonitor(ref, [:flush])
      result
    end
  end

  defmodule Blocks do
    @moduledoc """
    No `after`, so the receive consumes either the reply or the {:DOWN, ...}
    and the monitor cannot outlive the wait.
    """
    def wait(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
        {:reply, ^ref, value} -> value
      end
    end
  end

  defmodule NoMonitor do
    @moduledoc "A timed receive with no monitor has nothing to leak."
    def wait do
      receive do
        :ok -> :ok
      after
        1000 -> :timeout
      end
    end
  end
end
