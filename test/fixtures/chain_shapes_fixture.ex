# Chain shapes: a long and a short path between two servers (Short*),
# and a chain that would pass through a synchronous call cycle (Cyc*).

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
