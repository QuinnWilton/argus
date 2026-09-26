defmodule Argus.Test.Fixtures.StaticRender do
  @moduledoc false
  # LiveView callbacks that run on the static render too, registering
  # the process for later messages (mailbox's static_render_registration).

  # livebook before a05d6c5: the hub page subscribed in mount/3 with no
  # connected? test.
  defmodule Subscribes do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def mount(_params, _session, socket) do
      Phoenix.PubSub.subscribe(:pubsub, "hubs")
      {:ok, socket}
    end
  end

  # Logflare before ec7331b: a one-second interval armed in mount/3.
  defmodule Ticks do
    @moduledoc false
    @behaviour Phoenix.LiveView

    @impl true
    def mount(_params, _session, socket) do
      :timer.send_interval(1_000, self(), :update_cluster_status)
      {:ok, socket}
    end
  end

  # The fixes: behind connected?/1, in mount/3 or around the call into a
  # helper.
  defmodule Guarded do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub, {Phoenix.LiveView, :connected?, 1}]}

    @impl true
    def mount(_params, _session, socket) do
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(:pubsub, "hubs")
        :timer.send_interval(1_000, self(), :tick)
      end

      {:ok, socket}
    end

    @impl true
    def handle_params(_params, _uri, socket) do
      if Phoenix.LiveView.connected?(socket), do: subscribe_all()
      {:noreply, socket}
    end

    defp subscribe_all, do: Phoenix.PubSub.subscribe(:pubsub, "devices")
  end

  # A connected? test that decides something else guards nothing: the
  # subscription after it runs on both renders, through a helper too.
  defmodule AskedElsewhere do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub, {Phoenix.LiveView, :connected?, 1}]}

    @impl true
    def mount(_params, _session, socket) do
      status = if Phoenix.LiveView.connected?(socket), do: :live, else: :static
      subscribe_all()
      {:ok, {socket, status}}
    end

    defp subscribe_all, do: Phoenix.PubSub.subscribe(:pubsub, "devices")
  end

  # Through the socket's endpoint, an apply.
  defmodule EndpointSubscribes do
    @moduledoc false
    @behaviour Phoenix.LiveView

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      socket.endpoint.subscribe("device:#{id}")
      {:ok, socket}
    end
  end

  # Beside each quieting condition, the nearest shapes that still
  # register on the static render: the test on the wrong arm, a helper
  # reached from a wrong arm or after the join, and an endpoint's
  # subscribe/1 called by name.
  defmodule Adversarial do
    @moduledoc false
    alias Argus.Test.Fixtures.StaticRender.{Endpoint, MoreTopics, Topics}

    defmodule ElseArm do
      @moduledoc false
      @behaviour Phoenix.LiveView
      @compile {:no_warn_undefined, [Phoenix.PubSub, {Phoenix.LiveView, :connected?, 1}]}

      @impl true
      def mount(_params, _session, socket) do
        if Phoenix.LiveView.connected?(socket),
          do: :ok,
          else: Phoenix.PubSub.subscribe(:pubsub, "hubs")

        {:ok, socket}
      end
    end

    defmodule Unless do
      @moduledoc false
      @behaviour Phoenix.LiveView
      @compile {:no_warn_undefined, [{Phoenix.LiveView, :connected?, 1}]}

      @impl true
      def mount(_params, _session, socket) do
        unless Phoenix.LiveView.connected?(socket),
          do: :timer.send_interval(1_000, self(), :tick)

        {:ok, socket}
      end
    end

    defmodule HelperOnFalseArm do
      @moduledoc false
      @behaviour Phoenix.LiveView
      @compile {:no_warn_undefined, [{Phoenix.LiveView, :connected?, 1}]}

      @impl true
      def mount(_params, _session, socket) do
        if Phoenix.LiveView.connected?(socket), do: :ok, else: Topics.subscribe_all()
        {:ok, socket}
      end
    end

    defmodule HelperBothSides do
      @moduledoc false
      @behaviour Phoenix.LiveView
      @compile {:no_warn_undefined, [{Phoenix.LiveView, :connected?, 1}]}

      @impl true
      def mount(_params, _session, socket) do
        if Phoenix.LiveView.connected?(socket), do: MoreTopics.subscribe_all()
        MoreTopics.subscribe_all()
        {:ok, socket}
      end
    end

    defmodule HandedAfterJoin do
      @moduledoc false
      @behaviour Phoenix.LiveView
      @compile {:no_warn_undefined, [Phoenix.PubSub, {Phoenix.LiveView, :connected?, 1}]}

      @impl true
      def mount(%{"ids" => ids}, _session, socket) do
        live = Phoenix.LiveView.connected?(socket)
        Enum.each(ids, fn id -> Phoenix.PubSub.subscribe(:pubsub, "item:#{id}") end)
        {:ok, {socket, live}}
      end
    end

    defmodule NamedEndpoint do
      @moduledoc false
      @behaviour Phoenix.LiveView

      @impl true
      def mount(_params, _session, socket) do
        Endpoint.subscribe("hubs")
        {:ok, socket}
      end
    end
  end

  defmodule Topics do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def subscribe_all, do: Phoenix.PubSub.subscribe(:pubsub, "all")
  end

  defmodule MoreTopics do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def subscribe_all, do: Phoenix.PubSub.subscribe(:pubsub, "more")
  end

  defmodule Endpoint do
    @moduledoc false
    @compile {:no_warn_undefined, [Phoenix.PubSub]}
    def __sockets__, do: []
    def subscribe(topic), do: Phoenix.PubSub.subscribe(:pubsub, topic)
  end

  # A LiveComponent's update/2 runs on the static render as well.
  defmodule Component do
    @moduledoc false
    @behaviour Phoenix.LiveComponent

    @impl true
    def update(assigns, socket) do
      Process.monitor(assigns.pid)
      {:ok, socket}
    end
  end

  # A handle_event/3 runs only connected: no finding.
  defmodule EventOnly do
    @moduledoc false
    @behaviour Phoenix.LiveView
    @compile {:no_warn_undefined, [Phoenix.PubSub]}

    @impl true
    def handle_event("follow", _params, socket) do
      Phoenix.PubSub.subscribe(:pubsub, "follows")
      {:noreply, socket}
    end
  end
end
