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

defmodule Argus.Test.Fixtures.OrphanStateStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :idle, %{}}

  def idle(:cast, :go, data) do
    {:next_state, :running, data}
  end

  def running(:cast, :stop, data) do
    {:next_state, :idle, data}
  end

  # Dead state: nothing transitions to it and it never transitions out —
  # unreachable AND terminal.
  def abandoned(_event, _msg, _data) do
    exit(:unreachable)
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end

defmodule Argus.Test.Fixtures.DelegatingStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :idle, %{}}

  # Both state functions delegate to a helper, so the extractor sees the
  # states but none of their transitions — an extraction gap, not a
  # machine with no edges. Must produce zero structural findings.
  #
  # The helper chain is two levels deep because an arity-3 helper is
  # itself picked up as a state function, and a recognizable return
  # tuple in it would count as an extracted transition.
  def idle(type, msg, data), do: dispatch(type, msg, data)
  def busy(type, msg, data), do: dispatch(type, msg, data)

  defp dispatch(_type, _msg, data), do: keep(data)

  defp keep(data), do: {:keep_state, data}

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end

defmodule Argus.Test.Fixtures.PrivateHelperStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :idle, %{items: []}}

  # Real states — exported, arity 3.
  def idle(:cast, :go, data), do: {:next_state, :running, normalize(data)}

  def running(:cast, :stop, data) do
    # An anonymous closure the compiler lifts to a private arity-3
    # top-level function (`-running/3-fun-0-`). It must not register as a
    # state.
    filtered = Enum.map(data.items, fn item -> {item, :running, data} end)
    {:next_state, :idle, %{data | items: filtered}}
  end

  # A private arity-3 helper — same shape as a state function but not a
  # state. Must not register as a state.
  defp normalize(data, extra \\ [], _opts \\ []) do
    %{data | items: data.items ++ extra}
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end
