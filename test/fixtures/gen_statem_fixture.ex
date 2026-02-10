defmodule Argus.Test.Fixtures.SimpleStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :idle, %{}}

  def idle(:cast, :start, data) do
    {:next_state, :running, data}
  end

  def idle(:cast, _, data) do
    {:keep_state, data}
  end

  def running(:cast, :stop, data) do
    {:next_state, :idle, data}
  end

  def running(:cast, :finish, data) do
    {:stop, :normal, data}
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end

defmodule Argus.Test.Fixtures.TimeoutStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :waiting, %{}}

  def waiting(:cast, :begin, data) do
    {:next_state, :processing, data, [{:state_timeout, 5000, :timeout}]}
  end

  def processing(:state_timeout, :timeout, data) do
    {:next_state, :waiting, data}
  end

  def processing(:cast, :done, data) do
    {:next_state, :waiting, data}
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end
