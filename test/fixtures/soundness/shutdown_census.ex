defmodule Argus.Test.Soundness.Census.Shutdown do
  @moduledoc """
  Suppression counterexamples and nearby variants: "Server
  terminates a process it still monitors" was excused by any demonitor
  anywhere in the module, and did not tie the killed process to the
  monitored one. Asserted by test/soundness/shutdown_test.exs.
  """
end

defmodule Argus.Test.Soundness.Census.Shutdown.Job do
  @moduledoc "A job a runner starts under a DynamicSupervisor."
  use GenServer, restart: :temporary

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}
end

defmodule Argus.Test.Soundness.Census.Shutdown.Runner do
  @moduledoc """
  The census program: :pkill terminates the job this server monitors, and
  the :DOWN lands in the clause written for crashes, which starts the job
  again. The only demonitor is :unwatch's, of an unrelated observer's
  monitor.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Shutdown.Job

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_job(%{opts: opts, job: nil, job_ref: nil, watch_ref: nil})}

  @impl true
  def handle_call({:watch, pid}, _from, s),
    do: {:reply, :ok, %{s | watch_ref: Process.monitor(pid)}}

  def handle_call(:unwatch, _from, s) do
    Process.demonitor(s.watch_ref, [:flush])
    {:reply, :ok, %{s | watch_ref: nil}}
  end

  @impl true
  def handle_info(:pkill, s) do
    DynamicSupervisor.terminate_child(Argus.Test.Soundness.Census.Shutdown.JobSup, s.job)
    {:noreply, %{s | job: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job_ref: ref} = s),
    do: {:noreply, start_job(s)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{watch_ref: ref} = s),
    do: {:noreply, %{s | watch_ref: nil}}

  defp start_job(s) do
    {:ok, job} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Shutdown.JobSup, {Job, s.opts})

    %{s | job: job, job_ref: Process.monitor(job)}
  end
end

defmodule Argus.Test.Soundness.Census.Shutdown.Stopper do
  @moduledoc "The same shape with GenServer.stop as the kill."
  use GenServer

  alias Argus.Test.Soundness.Census.Shutdown.Job

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_job(%{opts: opts, job: nil, job_ref: nil, watch_ref: nil})}

  @impl true
  def handle_call({:watch, pid}, _from, s),
    do: {:reply, :ok, %{s | watch_ref: Process.monitor(pid)}}

  def handle_call(:unwatch, _from, s) do
    Process.demonitor(s.watch_ref, [:flush])
    {:reply, :ok, %{s | watch_ref: nil}}
  end

  @impl true
  def handle_info(:pkill, s) do
    GenServer.stop(s.job)
    {:noreply, %{s | job: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job_ref: ref} = s),
    do: {:noreply, start_job(s)}

  defp start_job(s) do
    {:ok, job} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Shutdown.JobSup, {Job, s.opts})

    %{s | job: job, job_ref: Process.monitor(job)}
  end
end

defmodule Argus.Test.Soundness.Census.Shutdown.HelperKiller do
  @moduledoc """
  The kill in a helper :pkill calls; the demonitor is in another helper
  that only :reset calls.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Shutdown.Job

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_job(%{opts: opts, job: nil, job_ref: nil})}

  @impl true
  def handle_info(:pkill, s), do: {:noreply, kill_job(s)}
  def handle_info(:reset, s), do: {:noreply, forget_job(s)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job_ref: ref} = s),
    do: {:noreply, start_job(s)}

  defp kill_job(s) do
    DynamicSupervisor.terminate_child(Argus.Test.Soundness.Census.Shutdown.JobSup, s.job)
    %{s | job: nil}
  end

  defp forget_job(s) do
    Process.demonitor(s.job_ref)
    %{s | job_ref: nil}
  end

  defp start_job(s) do
    {:ok, job} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Shutdown.JobSup, {Job, s.opts})

    %{s | job: job, job_ref: Process.monitor(job)}
  end
end

defmodule Argus.Test.Soundness.Census.Shutdown.ReleasingRunner do
  @moduledoc "Quiet: :pkill demonitors the job (with :flush) before it terminates it."
  use GenServer

  alias Argus.Test.Soundness.Census.Shutdown.Job

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, start_job(%{opts: opts, job: nil, job_ref: nil})}

  @impl true
  def handle_info(:pkill, s) do
    Process.demonitor(s.job_ref, [:flush])
    DynamicSupervisor.terminate_child(Argus.Test.Soundness.Census.Shutdown.JobSup, s.job)
    {:noreply, %{s | job: nil, job_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job_ref: ref} = s),
    do: {:noreply, start_job(s)}

  defp start_job(s) do
    {:ok, job} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Shutdown.JobSup, {Job, s.opts})

    %{s | job: job, job_ref: Process.monitor(job)}
  end
end

defmodule Argus.Test.Soundness.Census.Shutdown.Registry do
  @moduledoc "A named server the watcher below monitors."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Shutdown.UnwatchedKiller do
  @moduledoc """
  Quiet: it monitors the Registry by name and terminates a job it never
  monitored — the :DOWN of the kill never comes to it.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Shutdown.Job

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    ref = Process.monitor(Argus.Test.Soundness.Census.Shutdown.Registry)

    {:ok, job} =
      DynamicSupervisor.start_child(Argus.Test.Soundness.Census.Shutdown.JobSup, {Job, opts})

    {:ok, %{registry_ref: ref, job: job}}
  end

  @impl true
  def handle_info(:pkill, s) do
    DynamicSupervisor.terminate_child(Argus.Test.Soundness.Census.Shutdown.JobSup, s.job)
    {:noreply, %{s | job: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{registry_ref: ref} = s),
    do: {:stop, :registry_down, s}
end
