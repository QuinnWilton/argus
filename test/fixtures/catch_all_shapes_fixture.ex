defmodule Argus.Test.Fixtures.CatchAllShapes do
  @moduledoc false

  defmodule StatePatternCatchAll do
    @moduledoc false
    # gen_stage's fix for #238: the last clause accepts every message and
    # patterns the state — a catch-all for messages.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, {[], nil}}

    @impl true
    def handle_info(:stop, state), do: {:stop, :normal, state}
    def handle_info(_msg, {stack, continuation}), do: {:noreply, {stack, continuation}}
  end

  defmodule MapAccessBody do
    @moduledoc false
    # Two clauses, no catch-all; each body reads the state map, which
    # compiles to a test on the state before the body proper.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{acks: %{}, waiting: %{}}}

    @impl true
    def handle_cast({:ack, id, count}, state) do
      acks = Map.update(state.acks, id, count, &(&1 + count))
      {:noreply, %{state | acks: acks}}
    end

    def handle_cast({:rebalance, id}, state) do
      {:noreply, %{state | waiting: Map.delete(state.waiting, id)}}
    end
  end

  defmodule TaggedClausesWithStatePatterns do
    @moduledoc false
    # A socket owner's handle_info (redix): every clause matches a message
    # shape AND patterns the state, the tag is projected into a register
    # before a select, and one head fails on the state to the next clause.
    # No clause accepts every message.
    use GenServer

    defstruct [:conn, :socket]

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %__MODULE__{}}

    @impl true
    def handle_info({:force_disconnect, conn, reason}, %__MODULE__{conn: conn} = state) do
      {:stop, reason, state}
    end

    def handle_info({transport, socket, _data}, %__MODULE__{socket: socket} = state)
        when transport in [:tcp, :ssl] do
      {:noreply, state}
    end

    def handle_info({:tcp_closed, socket}, %__MODULE__{socket: socket} = state) do
      {:stop, :tcp_closed, state}
    end

    def handle_info({:tcp_error, socket, reason}, %__MODULE__{socket: socket} = state) do
      {:stop, {:tcp_error, reason}, state}
    end
  end

  defmodule SharedPrefixClauses do
    @moduledoc false
    # Two clauses share the tested prefix `{:DOWN, ref, _, _, _}`; the
    # first also matches the state (`%{lock: ref}`), the second takes any
    # state. The second is only as open as the shared prefix leaves it:
    # not a catch-all for messages (postgrex's type server).
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{lock: nil, waiting: %{}}}

    @impl true
    def handle_info({:DOWN, ref, _, _, _}, %{lock: ref} = state) when is_reference(ref) do
      {:noreply, %{state | lock: nil}}
    end

    def handle_info({:DOWN, ref, _, _, _}, state) do
      {:noreply, %{state | waiting: Map.delete(state.waiting, ref)}}
    end

    def handle_info(:timeout, state), do: {:stop, :normal, state}
  end
end
