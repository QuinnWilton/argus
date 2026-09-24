# Chain shapes: a long and a short path between two servers (Short*),
# a chain that would pass through a synchronous call cycle (Cyc*), and a
# chain beside a cycle through another clause of the same server (Fug*,
# encore's fugue: Countersubject -> Answer -> Subject, while Answer's
# :echo and Countersubject's :invert close a cycle, and :answer goes
# through the :local clause of a router whose :remote clause calls a
# server).

defmodule Argus.Test.Fixtures.ChainShapes.ShortA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.ShortB.ask(state)
    _ = Argus.Test.Fixtures.ChainShapes.ShortC.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.ShortB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.ShortC.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.ShortC do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.ShortD.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.ShortD do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.CycW do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.CycX.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.CycX do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.CycY.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.CycY do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    _ = Argus.Test.Fixtures.ChainShapes.CycX.ask(state)
    _ = Argus.Test.Fixtures.ChainShapes.CycZ.ask(state)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.CycZ do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def ask(_state), do: GenServer.call(__MODULE__, :ask)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask, _from, state) do
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.FugAnswer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def resolve(note), do: GenServer.call(__MODULE__, {:answer, note})
  def echo(note), do: GenServer.call(__MODULE__, {:echo, note})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:answer, note}, _from, state) do
    shaped = Argus.Test.Fixtures.ChainShapes.FugRouter.route(:local, note)
    {:subject, voiced} = Argus.Test.Fixtures.ChainShapes.FugSubject.observe(shaped)
    {:reply, {:answer, voiced}, state}
  end

  def handle_call({:echo, note}, _from, state) do
    {:reply, Argus.Test.Fixtures.ChainShapes.FugCounter.shadow(note), state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.FugCounter do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def invert(note), do: GenServer.call(__MODULE__, {:invert, note})
  def shadow(note), do: GenServer.call(__MODULE__, {:shadow, note})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:invert, note}, _from, state) do
    {:answer, resolved} = Argus.Test.Fixtures.ChainShapes.FugAnswer.resolve(127 - note)
    {:reply, {:countersubject, resolved}, state}
  end

  def handle_call({:shadow, note}, _from, state) do
    {:reply, {:shadow, rem(note * 2, 128)}, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.FugSubject do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def observe(note), do: GenServer.call(__MODULE__, {:observe, note})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:observe, note}, _from, state) do
    {:reply, {:subject, note}, state}
  end
end

defmodule Argus.Test.Fixtures.ChainShapes.FugRouter do
  @moduledoc false

  def route(:local, note), do: rem(note * 3 + 4, 128)

  def route(:remote, note),
    do: GenServer.call(Argus.Test.Fixtures.ChainShapes.FugRelay, {:relay, note})
end

defmodule Argus.Test.Fixtures.ChainShapes.FugRelay do
  @moduledoc false
  use GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:relay, note}, _from, state), do: {:reply, {:relayed, note}, state}
end
