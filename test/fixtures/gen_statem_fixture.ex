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

  # init/1 declares :idle as the entry point — read directly, so :idle is
  # never mistaken for an unreachable state despite having no incoming
  # transition of its own.
  @impl true
  def init(_args), do: {:ok, :idle, %{}}

  def idle(:cast, :go, data) do
    {:next_state, :running, data}
  end

  def running(:cast, :stop, data) do
    {:next_state, :idle, data}
  end

  # Dead state: it returns a real gen_statem action (so it IS a state
  # function, not a helper), but no transition ever targets it and it is
  # not the initial state — genuinely unreachable dead code.
  def abandoned(:cast, :never, data) do
    {:next_state, :running, data}
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
    # A locally-called, exported, arity-3 helper that returns a gen_statem
    # action tuple on the caller's behalf — the Redix `disconnect/3`
    # shape. It must not register as a state.
    finalize(%{data | items: filtered}, :idle, [])
  end

  def finalize(data, target, _opts) do
    {:next_state, target, data}
  end

  # A private arity-3 helper — same shape as a state function but not a
  # state. Must not register as a state.
  defp normalize(data, extra \\ [], _opts \\ []) do
    %{data | items: data.items ++ extra}
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end

defmodule Argus.Test.Fixtures.HandleEventStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  # Single sentinel state, à la DBConnection.Connection. The body matches
  # many atoms (message tags, commands) that are NOT states — the old
  # atom-harvesting extraction wrongly registered each as a phantom state.
  @impl true
  def init(_args), do: {:ok, :no_state, %{}}

  @impl true
  def handle_event({:call, from}, :connect, :no_state, data) do
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, :no_state, data) do
    {:stop, :shutdown, data}
  end

  def handle_event(:info, {:EXIT, _pid, _reason}, :no_state, data) do
    {:keep_state, data}
  end

  def handle_event(:cast, :ping, :no_state, _data) do
    :keep_state_and_data
  end

  @impl true
  def terminate(_reason, _state, _data), do: :ok
end

defmodule Argus.Test.Fixtures.AsymmetricInfoStatem do
  @moduledoc """
  The Redix Cluster.Manager shape: two states end with an :info catch-all,
  the third does not, and a stray message in that state is a crash.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :disconnected, %{}}

  def disconnected(:cast, :connect, data), do: {:next_state, :ready, data}
  def disconnected(:info, _msg, _data), do: :keep_state_and_data

  def ready(:cast, :disconnect, data), do: {:next_state, :cooling_down, data}
  def ready(:info, {:DOWN, _ref, :process, _pid, _reason}, data), do: {:keep_state, data}

  def cooling_down(:cast, :connect, data), do: {:next_state, :ready, data}
  def cooling_down(:info, _msg, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.SymmetricInfoStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :disconnected, %{}}

  def disconnected(:cast, :connect, data), do: {:next_state, :ready, data}
  def disconnected(:info, _msg, _data), do: :keep_state_and_data

  def ready(:cast, :disconnect, data), do: {:next_state, :disconnected, data}
  def ready(:info, {:DOWN, _ref, :process, _pid, _reason}, data), do: {:keep_state, data}
  def ready(:info, _msg, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.TimeoutMismatchStatem do
  @moduledoc """
  The Postgrex SimpleConnection shape: a {:timeout, ms, content} action
  is armed, and the handler is written for event type :info.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_args), do: {:ok, :connected, %{}}

  @impl true
  def handle_event(:cast, :activity, :connected, data) do
    {:keep_state, data, [{:timeout, 1000, nil}]}
  end

  def handle_event(:info, :timeout, :connected, data) do
    {:keep_state, Map.put(data, :pinged, true)}
  end

  def handle_event(:info, _msg, :connected, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.TimeoutHandledStatem do
  @moduledoc false
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_args), do: {:ok, :connected, %{}}

  @impl true
  def handle_event(:cast, :activity, :connected, data) do
    {:keep_state, data, [{:timeout, 1000, nil}]}
  end

  def handle_event(:timeout, nil, :connected, data) do
    {:keep_state, Map.put(data, :pinged, true)}
  end

  def handle_event(:info, _msg, :connected, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.GenericTimeoutMismatchStatem do
  @moduledoc """
  A generic timeout {{:timeout, :backoff}, ms, content} is armed, and
  the handler is written for the :timeout atom: the event arrives as
  {:timeout, :backoff}.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_args), do: {:ok, :disconnected, %{backoff: 100}}

  @impl true
  def handle_event(:internal, :connect, :disconnected, data) do
    {:keep_state, data, {{:timeout, :backoff}, data.backoff, nil}}
  end

  def handle_event(:timeout, nil, :disconnected, data) do
    {:keep_state, data, {:next_event, :internal, :connect}}
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.GenericTimeoutHandledStatem do
  @moduledoc """
  Postgrex.ReplicationConnection, Finch.HTTP2.Pool: the generic timeout
  is matched by a tuple head whose name varies, which compiles to a
  get_tuple_element and an atom test rather than is_tagged_tuple.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_args), do: {:ok, :disconnected, %{backoff: 100}}

  @impl true
  def handle_event(:internal, :connect, :disconnected, data) do
    {:keep_state, data, {{:timeout, :backoff}, data.backoff, nil}}
  end

  def handle_event({:timeout, name}, nil, :disconnected, data) do
    {:keep_state, Map.put(data, :last, name), {:next_event, :internal, :connect}}
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data
end

defmodule Argus.Test.Fixtures.UnrepliedCallStatem do
  @moduledoc false
  # finch#213: a cancel while disconnected returns :keep_state_and_data and
  # the caller waits forever.
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_args), do: {:ok, :disconnected, %{requests: %{}}}

  def disconnected({:call, from}, {:request, _req}, data) do
    {:keep_state, data, [{:reply, from, {:error, :disconnected}}]}
  end

  def disconnected({:call, _from}, {:cancel, _ref}, _data) do
    :keep_state_and_data
  end

  def disconnected(:info, :connect, data) do
    {:next_state, :connected, data}
  end

  def connected({:call, from}, {:request, req}, data) do
    {:keep_state, %{data | requests: Map.put(data.requests, req, from)}}
  end

  def connected({:call, from}, {:cancel, ref}, data) do
    :gen_statem.reply(from, :ok)
    {:keep_state, %{data | requests: Map.delete(data.requests, ref)}}
  end

  def connected({:call, _from}, :later, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def connected(:info, :disconnect, data) do
    {:next_state, :disconnected, data}
  end
end

defmodule Argus.Test.Fixtures.PendingCallStatem do
  @moduledoc false
  # A call clause that parks `from` in its data for a later reply. The
  # multi-line body saves the event to a y register and reads `from` from
  # there, not from {x,0}.
  @behaviour :gen_statem

  def start_link(_opts), do: :gen_statem.start_link({:local, __MODULE__}, __MODULE__, [], [])

  def drain(expected), do: :gen_statem.call(__MODULE__, {:drain, expected}, 60_000)

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(_opts), do: {:ok, :rising, %{count: 0, pending: nil}}

  @impl :gen_statem
  def handle_event({:call, from}, {:drain, expected}, _phase, data) do
    if data.count >= expected do
      {:keep_state_and_data, [{:reply, from, data.count}]}
    else
      {:keep_state, %{data | pending: {from, expected}}}
    end
  end

  # `from` lives in a y register across the local call and reaches
  # Map.put through an x register afterwards: kept.
  def handle_event({:call, from}, :later, _phase, data) do
    data = bump(data)
    {:keep_state, Map.put(data, :waiting, from)}
  end

  def handle_event(:cast, :pulse, phase, data) do
    data = bump(data)

    case data.pending do
      {from, expected} when data.count >= expected ->
        {:next_state, phase, %{data | pending: nil}, [{:reply, from, data.count}]}

      _ ->
        {:next_state, phase, data}
    end
  end

  defp bump(data), do: %{data | count: data.count + 1}
end
