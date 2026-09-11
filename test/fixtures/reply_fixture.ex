defmodule Argus.Test.Fixtures.Reply do
  @moduledoc """
  Fixtures for the reply-contract analysis.

  Each module holds exactly one `handle_call/3`, because retaining `from` is
  recorded per function: putting a correct clause and a broken one in the
  same module would mask the broken one, which is the analysis's known
  imprecision rather than a property worth fixturing.
  """

  defmodule Forgets do
    @moduledoc "The bug: defers, and drops `from` on the floor."
    use GenServer

    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_call(:work, _from, state), do: {:noreply, state}
  end

  defmodule RepliesDirectly do
    @moduledoc "The ordinary case. Nothing deferred, nothing to keep."
    use GenServer

    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_call(:work, _from, state), do: {:reply, :ok, state}
  end

  defmodule DefersProperly do
    @moduledoc "Stores `from`, replies from another callback."
    use GenServer

    def init(_), do: {:ok, %{waiting: nil}}

    @impl GenServer
    def handle_call(:work, from, state), do: {:noreply, %{state | waiting: from}}

    @impl GenServer
    def handle_info(:done, %{waiting: from} = state) do
      GenServer.reply(from, :ok)
      {:noreply, %{state | waiting: nil}}
    end
  end

  defmodule StoresAndForgets do
    @moduledoc """
    Keeps `from`, and the module replies nowhere. The shape a refactor
    leaves behind when the reply path is deleted: the storing half still
    reads correctly on its own.
    """
    use GenServer

    def init(_), do: {:ok, %{waiting: nil}}

    @impl GenServer
    def handle_call(:work, from, state), do: {:noreply, %{state | waiting: from}}

    @impl GenServer
    def handle_info(:done, state), do: {:noreply, state}
  end

  defmodule HandsOff do
    @moduledoc """
    Keeps `from` and sends it onward. Whoever receives it can reply, and
    this analysis is not looking there — so it must stay quiet.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_call({:work, worker}, from, state) do
      send(worker, {:job, from})
      {:noreply, state}
    end
  end

  defmodule StopsWithReply do
    @moduledoc "{:stop, reason, reply, state} answers the caller."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_call(:halt, _from, state), do: {:stop, :normal, :ok, state}
  end

  defmodule CastsAndInfos do
    @moduledoc """
    handle_cast/2 and handle_info/2 return {:noreply, _} because that is
    their only ordinary return. Nothing promised anyone anything.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_cast(:go, state), do: {:noreply, state}

    @impl GenServer
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule MixedClauses do
    @moduledoc """
    Three clauses in one function: one replies, one defers correctly, one
    forgets. The reason the fact is per return site — a function-level
    answer would let the correct clauses vouch for the broken one, and this
    is the shape the bug actually takes in the wild.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{waiting: nil}}

    @impl GenServer
    def handle_call(:now, _from, state), do: {:reply, :ok, state}
    def handle_call(:later, from, state), do: {:noreply, %{state | waiting: from}}
    def handle_call(:never, _from, state), do: {:noreply, state}

    @impl GenServer
    def handle_info(:done, %{waiting: from} = state) do
      GenServer.reply(from, :ok)
      {:noreply, %{state | waiting: nil}}
    end
  end

  defmodule PassesThrough do
    @moduledoc """
    Hands `from` straight to a helper in argument order, which compiles to
    a bare call with no moves: {x,1} is read without ever being mentioned.
    """
    use GenServer

    def init(_), do: {:ok, %{}}

    @impl GenServer
    def handle_call(:work, from, state), do: {:noreply, publish(:work, from, state)}

    def publish(_msg, from, state), do: Map.put(state, :waiting, from)
  end

  defmodule NotAGenServer do
    @moduledoc "A handle_call/3 outside a GenServer means nothing."
    def init(_), do: {:ok, %{}}
    def handle_call(:work, _from, state), do: {:noreply, state}
  end
end
