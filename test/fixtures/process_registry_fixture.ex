defmodule Argus.Test.Fixtures.ProcessRegisterer do
  @moduledoc false

  def register_name(pid) do
    Process.register(pid, :my_process)
  end

  def erlang_register(pid) do
    :erlang.register(:my_erlang_proc, pid)
  end
end

defmodule Argus.Test.Fixtures.NamedGenServer do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(_, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.WhereisModule do
  @moduledoc false

  def find_process(name) do
    Process.whereis(name)
  end

  def erlang_whereis(name) do
    :erlang.whereis(name)
  end

  def checked_whereis(name) do
    case Process.whereis(name) do
      nil -> :none
      pid -> send(pid, :hello)
    end
  end

  def checked_erlang_whereis(name) do
    case :erlang.whereis(name) do
      :undefined -> :none
      pid -> pid
    end
  end

  def unchecked_whereis(name) do
    send(Process.whereis(name), :hello)
  end
end

defmodule Argus.Test.Fixtures.RegistryUser do
  @moduledoc false

  def register(registry, key, value) do
    Registry.register(registry, key, value)
  end

  def lookup(registry, key) do
    Registry.lookup(registry, key)
  end
end

defmodule Argus.Test.Fixtures.DynamicNameServer do
  @moduledoc false
  # The registered name comes out of the caller's options — statically
  # unknowable. The extractor must record imprecision here, NOT a forged
  # ":dynamic" name (the inspect/1 rendering of the placeholder atom).
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Fixtures.DuplicateRegisterer do
  @moduledoc false

  # Registers the same :my_process name as ProcessRegisterer — whichever
  # runs second crashes with :badarg.
  def claim(pid) do
    Process.register(pid, :my_process)
  end
end

defmodule Argus.Test.Fixtures.StaticWhereis do
  @moduledoc false

  # whereis with a static name — the result can be nil at any moment
  # (TOCTOU) and this call site is what whereis_race flags.
  def lookup do
    Process.whereis(:my_process)
  end
end
