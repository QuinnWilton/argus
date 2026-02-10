defmodule Argus.Test.Fixtures.MyGenServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def get_value(server), do: GenServer.call(server, :get)

  def set_value(server, val), do: GenServer.cast(server, {:set, val})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:set, val}, _state), do: {:noreply, val}
end

defmodule Argus.Test.Fixtures.PlainModule do
  @moduledoc false

  def hello, do: :world
end

defmodule Argus.Test.Fixtures.AgentCaller do
  @moduledoc false

  def get_state(agent), do: Agent.get(agent, & &1)
  def update_state(agent, val), do: Agent.update(agent, fn _ -> val end)
  def get_and_update(agent), do: Agent.get_and_update(agent, &{&1, &1 + 1})
end

defmodule Argus.Test.Fixtures.ErlangStyleCaller do
  @moduledoc false

  def call_server(pid), do: :gen_server.call(pid, :ping)
  def cast_server(pid), do: :gen_server.cast(pid, :pong)
end

defmodule Argus.Test.Fixtures.MultiCallModule do
  @moduledoc false

  def multi_call_nodes(name, msg), do: GenServer.multi_call(name, msg)
end

defmodule Argus.Test.Fixtures.LinkMonitorModule do
  @moduledoc false

  def link_to(pid), do: Process.link(pid)
  def erlang_link(pid), do: :erlang.link(pid)
  def monitor_proc(pid), do: Process.monitor(pid)
  def erlang_monitor(pid), do: :erlang.monitor(:process, pid)
end
