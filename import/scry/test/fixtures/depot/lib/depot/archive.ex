defmodule Depot.Archive do
  @moduledoc """
  Persists completed jobs to long-term storage in the background.
  """

  @doc """
  Archives a completed job without waiting for the result.

  Leaked: the task is started with `Task.async/1` and never awaited, so
  its result vanishes and a crash takes the caller down with it — the
  shape `unsafe_task` reports.
  """
  @spec archive_async(map()) :: :ok
  def archive_async(job) do
    Task.async(fn -> write(job) end)
    :ok
  end

  @doc """
  Archives a completed job and waits for the result — the awaited
  counterpart, which is not reported.
  """
  @spec archive_sync(map()) :: {:ok, term()}
  def archive_sync(job) do
    task = Task.async(fn -> write(job) end)
    Task.await(task)
  end

  defp write(job) do
    {:ok, job.id}
  end
end
