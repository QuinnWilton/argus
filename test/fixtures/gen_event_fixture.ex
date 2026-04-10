defmodule Argus.Test.Fixtures.MyEventHandler do
  @moduledoc false
  @behaviour :gen_event

  @impl :gen_event
  def init(_args), do: {:ok, %{}}

  @impl :gen_event
  def handle_event(_event, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_msg, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @impl :gen_event
  def code_change(_old, state, _extra), do: {:ok, state}
end

defmodule Argus.Test.Fixtures.GenEventEmitter do
  @moduledoc false

  # Caller-side functions exercising every :gen_event API the extractor
  # cares about. Targets a static manager atom so resolve_callee/1 can
  # recover the module name.

  def sync_notify_event do
    :gen_event.sync_notify(MyEventManager, {:event, :data})
  end

  def notify_event do
    :gen_event.notify(MyEventManager, {:event, :data})
  end

  def call_handler do
    :gen_event.call(MyEventManager, Argus.Test.Fixtures.MyEventHandler, :get)
  end

  def call_handler_with_timeout do
    :gen_event.call(MyEventManager, Argus.Test.Fixtures.MyEventHandler, :get, 5000)
  end

  def install_handler do
    :gen_event.add_handler(MyEventManager, Argus.Test.Fixtures.MyEventHandler, [])
  end

  def install_sup_handler do
    :gen_event.add_sup_handler(MyEventManager, Argus.Test.Fixtures.MyEventHandler, [])
  end
end
