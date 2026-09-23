defmodule Argus.Test.Fixtures.PidCalls do
  @moduledoc """
  Synchronous calls whose target is a pid: the timeouts they carry
  (blocking's `:infinity` hop and budget rules) and calls a server makes
  to itself (gen exits them with `:calling_self`).
  """

  defmodule Waiter do
    @moduledoc "Answers a call by calling the Slow server it started, with :infinity."
    use GenServer

    alias Argus.Test.Fixtures.PidCalls.Slow

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, slow} = Slow.start_link()
      {:ok, %{slow: slow}}
    end

    @impl true
    def handle_call(:work, _from, s), do: {:reply, GenServer.call(s.slow, :work, :infinity), s}
  end

  defmodule Slow do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:work, _from, s), do: {:reply, :done, s}
  end

  defmodule Impatient do
    @moduledoc "Gives Middle one second, through the pid it started."
    use GenServer

    alias Argus.Test.Fixtures.PidCalls.Middle

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, middle} = Middle.start_link()
      {:ok, %{middle: middle}}
    end

    @impl true
    def handle_call(:ask, _from, s), do: {:reply, GenServer.call(s.middle, :ask, 1_000), s}
  end

  defmodule Middle do
    @moduledoc "Waits five seconds on Tail, through the pid it started."
    use GenServer

    alias Argus.Test.Fixtures.PidCalls.Tail

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, tail} = Tail.start_link()
      {:ok, %{tail: tail}}
    end

    @impl true
    def handle_call(:ask, _from, s), do: {:reply, GenServer.call(s.tail, :ask, 5_000), s}
  end

  defmodule Tail do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ask, _from, s), do: {:reply, :answer, s}
  end

  defmodule SelfCaller do
    @moduledoc """
    Calls itself from its own callbacks: by self(), by its registered
    name, and by self() handed to a helper. A cast to itself is fine.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:me, _from, s), do: {:reply, GenServer.call(self(), :ping), s}
    def handle_call(:named, _from, s), do: {:reply, GenServer.call(__MODULE__, :ping), s}
    def handle_call(:helper, _from, s), do: {:reply, ping(self()), s}
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}

    @impl true
    def handle_cast(:kick, s) do
      GenServer.cast(self(), :noop)
      {:noreply, s}
    end

    def handle_cast(:noop, s), do: {:noreply, s}

    defp ping(pid), do: GenServer.call(pid, :ping)
  end

  defmodule StatemFront do
    @moduledoc "A named gen_statem keeping the StatemPeer it started in its data, and calling it from a state."
    @behaviour :gen_statem

    alias Argus.Test.Fixtures.PidCalls.StatemPeer

    def start_link, do: :gen_statem.start_link({:local, __MODULE__}, __MODULE__, :ok, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(:ok) do
      {:ok, peer} = StatemPeer.start_link()
      {:ok, :idle, %{peer: peer}}
    end

    def idle({:call, from}, :ask, data) do
      # :ping names no server: only the data says where the call goes.
      answer = GenServer.call(data.peer, :ping)
      {:keep_state, data, [{:reply, from, answer}]}
    end

    def idle({:call, from}, :status, data), do: {:keep_state, data, [{:reply, from, :idle}]}
  end

  defmodule StatemPeer do
    @moduledoc "Answers by asking StatemFront, by name: a cycle through the statem's data."
    use GenServer

    alias Argus.Test.Fixtures.PidCalls.StatemFront

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, :gen_statem.call(StatemFront, :status), s}
  end
end
