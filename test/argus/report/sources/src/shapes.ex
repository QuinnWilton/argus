defmodule Shapes.Worker do
  # Never compiled: the renderer reads this file as the source a
  # finding's frame shows (Argus.Test.ReportShapes).
  use GenServer

  schema "jobs" do
    field(:api_key_count, :integer)
    field(:api_key, :string)
  end

  def fetch(url) do
    try do
      HTTP.get!(url)
    rescue
      error in HTTP.Error ->
        Logger.error("failed: #{inspect(error)}")
        :error
    end
  end

  def wait do
    receive do
      {:done, value} ->
        value

      :timeout ->
        nil
    end
  end

  def handle_info(:tick, state) do
    schedule()
    {:noreply, state}
  end

  # The data clause.
  def handle_info({:data, data}, state) do
    {:noreply, %{state | data: data}}
  end

  def run(job), do: job.()

  def guarded(fun) do
    fun.()
  catch
    :exit, reason -> {:error, reason}
  end
end
