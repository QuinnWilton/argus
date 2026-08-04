defmodule Argus.Test.Fixtures.MessageContract do
  @moduledoc """
  Fixtures for the message-contract analysis.

  The client half is a join over def_use rather than an extractor scan, so
  the pairs here vary the two things that join can get wrong: whether the
  tag reaching the call is the one textually nearest it, and whether the
  server discriminates on it.
  """

  defmodule Mismatch do
    @moduledoc "The bug: casts :put, handles :store."
    use GenServer

    def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
    def put(pid, k, v), do: GenServer.cast(pid, {:put, k, v})

    @impl GenServer
    def init(o), do: {:ok, o}

    @impl GenServer
    def handle_cast({:store, _k, _v}, s), do: {:noreply, s}
  end

  defmodule Agrees do
    @moduledoc "The same shape, with the halves in agreement."
    use GenServer

    def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
    def get(pid, k), do: GenServer.call(pid, {:get, k})

    @impl GenServer
    def init(o), do: {:ok, o}

    @impl GenServer
    def handle_call({:get, _k}, _f, s), do: {:reply, :ok, s}
  end

  defmodule CatchAll do
    @moduledoc "Disagrees, but accepts everything, so nothing can fail."
    use GenServer

    def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
    def poke(pid), do: GenServer.cast(pid, {:poke, 1})

    @impl GenServer
    def init(o), do: {:ok, o}

    @impl GenServer
    def handle_cast(_any, s), do: {:noreply, s}
  end

  defmodule StaleWrite do
    @moduledoc """
    The shape that made the first version unsound. An atom is written into
    the message register for an unrelated call, and a later cast's message
    arrives another way — a backward textual scan attributes the first to
    the second. A reaching-definition edge does not.
    """
    use GenServer

    def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

    def relay(pid, from, msg) do
      GenServer.reply(from, :ok)
      GenServer.cast(pid, msg)
    end

    @impl GenServer
    def init(o), do: {:ok, o}

    @impl GenServer
    def handle_cast({:relayed, _}, s), do: {:noreply, s}
  end
end
