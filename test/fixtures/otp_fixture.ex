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

defmodule Argus.Test.Fixtures.ExplicitTimeoutCaller do
  @moduledoc false

  def call_with_default(server), do: GenServer.call(server, :ping)
  def call_with_explicit(server), do: GenServer.call(server, :ping, 10_000)
  def call_with_infinity(server), do: GenServer.call(server, :ping, :infinity)
  def erlang_call_with_timeout(server), do: :gen_server.call(server, :ping, 15_000)
end

defmodule Argus.Test.Fixtures.DeferredReplyServer do
  @moduledoc false

  # Stashes the from reference in state, replies later from handle_info.
  # The OTP extractor records GenServer.reply/2 as a deferred_reply fact
  # with the from arg classified as a function parameter.

  def reply_immediately(from, value) do
    GenServer.reply(from, value)
  end

  def erlang_reply(from, value) do
    :gen_server.reply(from, value)
  end
end

defmodule Argus.Test.Fixtures.DelayedMessageSender do
  @moduledoc false

  # Common patterns that schedule a future message to a process. The OTP
  # extractor records each as a delayed_message fact.

  def schedule_self_tick do
    Process.send_after(self(), :tick, 1000)
  end

  def schedule_named_tick do
    Process.send_after(:my_named_proc, :tick, 1000)
  end

  def schedule_with_options(target) do
    Process.send_after(target, {:retry, 3}, 5000, abs: false)
  end

  def erlang_send_after do
    :erlang.send_after(1000, :my_named_proc, :erlang_tick)
  end

  def timer_send_after_self do
    :timer.send_after(1000, :timer_tick)
  end

  def timer_send_after_dest do
    :timer.send_after(1000, :my_named_proc, :timer_tick)
  end

  def timer_apply_after do
    :timer.apply_after(5000, MyModule, :do_work, [])
  end
end

defmodule Argus.Test.Fixtures.ViaTupleCaller do
  @moduledoc false

  # Calls through a literal {:via, Registry, _} tuple. The OTP extractor
  # should resolve x0 to the via shape and emit a sync_call_via fact for
  # the registry/key pair, alongside the regular sync_call.
  def get(key) do
    GenServer.call({:via, Registry, {MyApp.Registry, key}}, :get)
  end

  def cast_to(key, msg) do
    GenServer.cast({:via, Registry, {MyApp.Registry, key}}, msg)
  end
end
