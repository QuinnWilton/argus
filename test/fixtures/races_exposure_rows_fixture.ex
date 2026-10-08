defmodule Argus.Test.Fixtures.RacesExposureRows do
  @moduledoc """
  Rows of one session kept under tuple keys in one public table, as
  phoenix_replay's session buffer keeps them: `{id, :meta}`, `{id, :seq}`,
  `{id, :state}`, events at `{id, seq}` and collected counts at
  `{:collected, id, name}`. A tuple key of another arity, or with another
  literal at the same position, names another row. The recorder, one
  named process, reads and rewrites the `:meta` row; any process may
  call the module's other functions.
  """

  defmodule Sibling do
    @moduledoc "Every write beside the recorder's is to a sibling row."
    use GenServer

    @table :races_exposure_sibling

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:named_table, :public, :ordered_set])
      {:ok, state}
    end

    def put_url(id, url), do: GenServer.cast(__MODULE__, {:put_url, id, url})

    @impl true
    def handle_cast({:put_url, id, url}, state) do
      case :ets.lookup(@table, {id, :meta}) do
        [{key, pid, recording}] ->
          :ets.insert(@table, {key, pid, %{recording | url: url}})

        [] ->
          :ok
      end

      {:noreply, state}
    end

    def flushed(id, chunk) do
      Enum.each(chunk, fn {seq, _event} -> :ets.delete(@table, {id, seq}) end)
      :ok
    end

    def collect(id, name), do: :ets.insert(@table, {{:collected, id, name}, 1})

    def drop(id) do
      :ets.delete(@table, {id, :seq})
      :ets.delete(@table, {id, :state})
      :ets.delete(@table, {id, :saving})
      :ok
    end
  end

  defmodule SameRow do
    @moduledoc """
    The same recorder, and an API that also deletes the `:meta` row: the
    delete can land between the lookup and the insert, and the insert
    puts the deleted row back.
    """
    use GenServer

    @table :races_exposure_same_row

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:named_table, :public, :ordered_set])
      {:ok, state}
    end

    def put_url(id, url), do: GenServer.cast(__MODULE__, {:put_url, id, url})

    @impl true
    def handle_cast({:put_url, id, url}, state) do
      case :ets.lookup(@table, {id, :meta}) do
        [{key, pid, recording}] ->
          :ets.insert(@table, {key, pid, %{recording | url: url}})

        [] ->
          :ok
      end

      {:noreply, state}
    end

    def drop(id) do
      :ets.delete(@table, {id, :seq})
      :ets.delete(@table, {id, :meta})
      :ok
    end
  end
end
