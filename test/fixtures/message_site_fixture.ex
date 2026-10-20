defmodule Argus.Test.Fixtures.MessageSite do
  @moduledoc """
  Clients whose calls carry their parameters to a server that makes atoms
  of what it is handed, or to one that only echoes it: a message reaches
  the server of the call that carries it, whichever others its function
  calls.
  """

  defmodule Atoms do
    @moduledoc "Interns the names its clients hand it."
    use GenServer

    def init(state), do: {:ok, state}
    def handle_call({:intern, name}, _from, state), do: {:reply, String.to_atom(name), state}
    def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}
  end

  defmodule Echo do
    @moduledoc "Hands back what it is handed."
    use GenServer

    def init(state), do: {:ok, state}
    def handle_call({:echo, term}, _from, state), do: {:reply, term, state}
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
end
