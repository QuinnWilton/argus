defmodule Argus.Test.Fixtures.Resubscribe do
  @moduledoc false
  # Subscriptions made again each time a callback runs (mailbox's
  # repeated_subscription).

  # A server that subscribes on every tick.
  defmodule Ticker do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      Process.send_after(self(), :refresh, 5_000)
      {:ok, state}
    end

    @impl true
    def handle_info(:refresh, state) do
      Phoenix.PubSub.subscribe(:pubsub, "jobs")
      Process.send_after(self(), :refresh, 5_000)
      {:noreply, state}
    end
  end

  # Subscribing once, in init/1, is the fix.
  defmodule Once do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      Phoenix.PubSub.subscribe(:pubsub, "jobs")
      {:ok, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  # nerves_hub_web before 59dd4c6: the device list re-subscribes every
  # device through the socket's endpoint on each refresh.
  defmodule DeviceList do
    @moduledoc false
    @behaviour Phoenix.LiveView

    @impl true
    def handle_info(:refresh_device_list, socket) do
      subscribe_all(socket)
      {:noreply, socket}
    end

    defp subscribe_all(socket) do
      Enum.each(socket.assigns.devices, fn device ->
        socket.endpoint.subscribe("device:#{device.identifier}:internal")
      end)
    end
  end

  # The fix: the old subscriptions undone before the new ones.
  defmodule DeviceListFixed do
    @moduledoc false
    @behaviour Phoenix.LiveView

    @impl true
    def handle_info(:refresh_device_list, socket) do
      Enum.each(socket.assigns.old_devices, fn device ->
        socket.endpoint.unsubscribe("device:#{device.identifier}:internal")
      end)

      Enum.each(socket.assigns.devices, fn device ->
        socket.endpoint.subscribe("device:#{device.identifier}:internal")
      end)

      {:noreply, socket}
    end
  end

  # livebook before 3e63097: App.unsubscribe/1 subscribed.
  defmodule Apps do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def subscribe(slug), do: Phoenix.PubSub.subscribe(:pubsub, "apps:#{slug}")
    def unsubscribe(slug), do: Phoenix.PubSub.subscribe(:pubsub, "apps:#{slug}")
  end

  defmodule Session do
    @moduledoc false
    @behaviour Phoenix.LiveView
    alias Argus.Test.Fixtures.Resubscribe.Apps

    @impl true
    def handle_event("deploy", %{"old" => old, "new" => new}, socket) do
      Apps.unsubscribe(old)
      Apps.subscribe(new)
      {:noreply, socket}
    end
  end

  # An endpoint's subscribe/1, named: the module is an endpoint.
  defmodule Endpoint do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def __sockets__, do: []
    def subscribe(topic), do: Phoenix.PubSub.subscribe(:pubsub, topic)
  end

  defmodule Channel do
    @moduledoc false
    @behaviour Phoenix.Channel
    alias Argus.Test.Fixtures.Resubscribe.Endpoint

    @impl true
    def handle_in("watch", %{"id" => id}, socket) do
      Endpoint.subscribe("watch:#{id}")
      {:noreply, socket}
    end
  end

  # Beside the quieting condition (the same callback unsubscribes), the
  # nearest shapes that still repeat: an unsubscribe only in terminate/2,
  # one only in another callback, one a helper of another entry makes;
  # and a LiveView's handle_params/3, which live navigation runs again.
  defmodule UnsubscribesAtStop do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:watch, topic}, state) do
      Phoenix.PubSub.subscribe(:pubsub, topic)
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, state) do
      Phoenix.PubSub.unsubscribe(:pubsub, "all")
      state
    end
  end

  defmodule UnsubscribesElsewhere do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def handle_event("follow", %{"id" => id}, socket) do
      Phoenix.PubSub.subscribe(:pubsub, "user:#{id}")
      {:noreply, socket}
    end

    @impl true
    def handle_info({:left, id}, socket) do
      Phoenix.PubSub.unsubscribe(:pubsub, "user:#{id}")
      {:noreply, socket}
    end
  end

  defmodule Rooms do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def subscribe(room), do: Phoenix.PubSub.subscribe(:pubsub, "room:#{room}")
    def leave(room), do: Phoenix.PubSub.unsubscribe(:pubsub, "room:#{room}")
  end

  defmodule HelperOfAnotherEntry do
    @moduledoc false
    use GenServer
    alias Argus.Test.Fixtures.Resubscribe.Rooms

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:deployed, slug}, state) do
      Rooms.subscribe(slug)
      {:noreply, state}
    end

    @impl true
    def handle_call({:undeploy, slug}, _from, state) do
      Rooms.leave(slug)
      {:reply, :ok, state}
    end
  end

  defmodule Navigates do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def handle_params(%{"id" => id}, _uri, socket) do
      Phoenix.PubSub.subscribe(:pubsub, "post:#{id}")
      {:noreply, socket}
    end
  end

  # A clause for a message the process sends itself only from init/1
  # runs once (nerves_hub_web's ExtensionsChannel `:init_extensions`).
  defmodule OnceFromInit do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      send(self(), :subscribe)
      {:ok, state}
    end

    @impl true
    def handle_info(:subscribe, state) do
      Phoenix.PubSub.subscribe(:pubsub, "once")
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  # Beside it: the message sent again from a handler, a subscription in
  # another clause, the message re-armed by a timer.
  defmodule SentAgain do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      send(self(), :subscribe)
      {:ok, state}
    end

    @impl true
    def handle_cast(:reconnect, state) do
      send(self(), :subscribe)
      {:noreply, state}
    end

    @impl true
    def handle_info(:subscribe, state) do
      Phoenix.PubSub.subscribe(:pubsub, "again")
      {:noreply, state}
    end
  end

  defmodule OtherClause do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      send(self(), :subscribe)
      {:ok, state}
    end

    @impl true
    def handle_info(:subscribe, state) do
      Phoenix.PubSub.subscribe(:pubsub, "first")
      {:noreply, state}
    end

    def handle_info(:refresh, state) do
      Phoenix.PubSub.subscribe(:pubsub, "refreshed")
      {:noreply, state}
    end
  end

  defmodule Rearmed do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state) do
      send(self(), :subscribe)
      {:ok, state}
    end

    @impl true
    def handle_info(:subscribe, state) do
      Phoenix.PubSub.subscribe(:pubsub, "rearmed")
      Process.send_after(self(), :subscribe, 60_000)
      {:noreply, state}
    end
  end

  # A callback that asks its own state first (teiserver's fix, firezone's
  # scope-restart re-join) keeps its subscriptions.
  defmodule StateChecked do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:subscribe, id}, _from, state) do
      if MapSet.member?(state.subscribed, id) do
        {:reply, :ok, state}
      else
        Phoenix.PubSub.subscribe(:pubsub, "user:#{id}")
        {:reply, :ok, %{state | subscribed: MapSet.put(state.subscribed, id)}}
      end
    end
  end

  defmodule ScopeRestart do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(:register, state) do
      current = state.scope_pid

      case Process.whereis(:portal) do
        ^current ->
          {:noreply, state}

        new ->
          :pg.join(:portal, :clients, self())
          {:noreply, %{state | scope_pid: new}}
      end
    end
  end

  # Beside it: a state test that decides something else, a test of the
  # message alone, a match on the state that only raises when it fails.
  defmodule StateAskedElsewhere do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:subscribe, id}, _from, state) do
      if state.verbose, do: IO.puts("subscribing #{id}")
      Phoenix.PubSub.subscribe(:pubsub, "user:#{id}")
      {:reply, :ok, state}
    end
  end

  defmodule MessageDecided do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:watch, topic, true}, state) do
      Phoenix.PubSub.subscribe(:pubsub, topic)
      {:noreply, state}
    end

    def handle_cast({:watch, _topic, false}, state), do: {:noreply, state}
  end

  defmodule StateMatchRaises do
    @moduledoc false
    use GenServer
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:refresh, ids}, state) do
      %{prefix: prefix} = state
      Enum.each(ids, fn id -> Phoenix.PubSub.subscribe(:pubsub, "#{prefix}:#{id}") end)
      {:noreply, state}
    end
  end

  # firezone's re-join after its :pg scope restarts: the state test is
  # in a helper the callback hands the state to.
  defmodule HelperStateChecked do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(:register, state), do: {:noreply, register(state)}

    defp register(state) do
      current = state.scope_pid

      case Process.whereis(:portal) do
        ^current ->
          state

        new ->
          :pg.join(:portal, :clients, self())
          %{state | scope_pid: new}
      end
    end
  end

  # Beside it: a helper whose state test decides something else.
  defmodule HelperStateElsewhere do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(:register, state), do: {:noreply, register(state)}

    defp register(state) do
      if state.verbose, do: IO.puts("joining")
      :pg.join(:portal, :clients, self())
      state
    end
  end
end
