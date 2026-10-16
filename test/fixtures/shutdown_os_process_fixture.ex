defmodule Argus.Test.Fixtures.ShutdownOsProcess do
  @moduledoc """
  Tasks that run an external program and are killed, for
  `orphaned_os_process`: a killed task closes its port, and the program
  it spawned runs on. The quiet neighbours wait for their task, or kill
  one that runs no program.
  """

  defmodule Render do
    @moduledoc "Primer's first PDF render: the task is shut down when it overruns."
    def pdf(chrome, args, timeout) do
      task =
        Task.Supervisor.async_nolink(Argus.Test.Fixtures.ShutdownOsProcess.Tasks, fn ->
          System.cmd(chrome, args, stderr_to_stdout: true)
        end)

      Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
    end
  end

  defmodule RenderThroughHelper do
    @moduledoc "Render's twin whose task reaches the program through a helper."
    def pdf(args, timeout) do
      task = Task.async(fn -> convert(args) end)
      Task.yield(task, timeout) || Task.shutdown(task)
    end

    defp convert(args), do: System.cmd("convert", args)
  end

  defmodule Killer do
    @moduledoc "A task holding a port to a program, killed by its pid."
    def run(path) do
      task =
        Task.async(fn ->
          port = Port.open({:spawn_executable, path}, [:binary, :exit_status])

          receive do
            {^port, {:exit_status, status}} -> status
          end
        end)

      Process.sleep(1_000)
      Process.exit(task.pid, :kill)
    end
  end

  defmodule Waits do
    @moduledoc "The program's task is waited for, never killed."
    def run(args) do
      fn -> System.cmd("git", args) end
      |> Task.async()
      |> Task.await(:infinity)
    end
  end

  defmodule ShutsDownPure do
    @moduledoc "A task shut down on overrun that runs no program."
    def run(n, timeout) do
      task = Task.async(fn -> Enum.sum(1..n) end)
      Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
    end
  end
end
