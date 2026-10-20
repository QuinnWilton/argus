defmodule Argus.Test.Fixtures.MessageSite do
  @moduledoc """
  Clients whose calls carry their parameters to a server that makes atoms
  of what it is handed, or to one that only echoes it: a message reaches
  the server of the call that carries it, whichever others its function
  calls.
  """

  defmodule Atoms do
    @moduledoc "Interns the names its clients hand it, asked or sent."
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

    def init(state), do: {:ok, state}
    def handle_call({:intern, name}, _from, state), do: {:reply, String.to_atom(name), state}
    def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}

    def handle_info({:intern, name}, state),
      do: {:noreply, Map.put(state, String.to_atom(name), true)}
  end

  defmodule Echo do
    @moduledoc "Hands back what it is handed, and keeps what it is sent."
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

    def init(state), do: {:ok, state}
    def handle_call({:echo, term}, _from, state), do: {:reply, term, state}
    def handle_info({:keep, term}, state), do: {:noreply, Map.put(state, :last, term)}
  end

  defmodule Mixed do
    @moduledoc "The name goes to Echo; Atoms is asked for its stats alone."
    def run(name) do
      echoed = GenServer.call(Echo, {:echo, name})
      {echoed, GenServer.call(Atoms, :stats)}
    end
  end

  defmodule Interns do
    @moduledoc "The name goes to Atoms."
    def run(name), do: GenServer.call(Atoms, {:intern, name})
  end

  defmodule OwnServer do
    @moduledoc "The name goes to an Atoms server the client starts: a pid, not a name."
    def run(name) do
      {:ok, pid} = GenServer.start_link(Atoms, %{})
      GenServer.call(pid, {:intern, name})
    end
  end

  defmodule SendsName do
    @moduledoc "The name is sent to Atoms by its registered name."
    def run(name), do: send(Atoms, {:intern, name})
  end

  defmodule SendsPid do
    @moduledoc "The name is sent to an Atoms server the client starts."
    def run(name) do
      {:ok, pid} = GenServer.start_link(Atoms, %{})
      send(pid, {:intern, name})
    end
  end

  defmodule ProcessSends do
    @moduledoc "The same through Process.send/3, a call."
    def run(name) do
      {:ok, pid} = GenServer.start_link(Atoms, %{})
      Process.send(pid, {:intern, name}, [])
    end
  end

  defmodule SendsEcho do
    @moduledoc "The name is sent to Echo; Atoms is only asked for its stats."
    def run(name) do
      send(Echo, {:keep, name})
      GenServer.call(Atoms, :stats)
    end
  end
end
