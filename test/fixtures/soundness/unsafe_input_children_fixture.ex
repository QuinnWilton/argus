defmodule Argus.Test.Soundness.UnsafeInput.Children do
  @moduledoc """
  Requests that start a child per event on an uncapped supervisor and
  leave it alive on some path, each with a supervisor of its own:
  `test/soundness/unsafe_input_test.exs` asserts the finding each must
  keep.
  """

  defmodule Worker do
    @moduledoc false
    use GenServer
    def start_link(o), do: GenServer.start_link(__MODULE__, o)
    @impl GenServer
    def init(o), do: {:ok, o}
  end

  defmodule ReplySup do
    @moduledoc false
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule TimedSup do
    @moduledoc false
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule AnyDownSup do
    @moduledoc false
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule TwiceSup do
    @moduledoc false
    use DynamicSupervisor
    def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
    @impl DynamicSupervisor
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── A start whose caller waits out the child, on every path ─────────
  # (review 2, item 5: 5515ef7c stopped at the loop_rec of a receive with
  # a :DOWN clause, even on the path of its other clause.)

  defmodule ReplyLive do
    @moduledoc """
    Starts a worker per event and waits for it to say it is ready (or to
    die). On the ready path the worker lives on after the request: one
    more child per event.
    """
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Soundness.UnsafeInput.Children.ReplySup,
          Argus.Test.Soundness.UnsafeInput.Children.Worker
        )

      ref = Process.monitor(pid)

      receive do
        {:ready, ^pid} ->
          Process.demonitor(ref, [:flush])
          {:noreply, socket}

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          {:noreply, socket}
      end
    end

    def render(assigns), do: assigns
  end

  defmodule TimedLive do
    @moduledoc "Waits for the child's :DOWN with an `after`: past it, the child lives on."
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Soundness.UnsafeInput.Children.TimedSup,
          Argus.Test.Soundness.UnsafeInput.Children.Worker
        )

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> {:noreply, socket}
      after
        5_000 -> {:noreply, socket}
      end
    end

    def render(assigns), do: assigns
  end

  defmodule AnyDownLive do
    @moduledoc "Any monitor's :DOWN, or the child's result: the result path leaves it alive."
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Soundness.UnsafeInput.Children.AnyDownSup,
          Argus.Test.Soundness.UnsafeInput.Children.Worker
        )

      Process.monitor(pid)

      receive do
        {:DOWN, _, :process, _, _} -> {:noreply, socket}
        {:done, result} -> {:noreply, Map.put(socket, :result, result)}
      end
    end

    def render(assigns), do: assigns
  end

  defmodule TwiceLive do
    @moduledoc "The first start is waited out; the second is not."
    @behaviour Phoenix.LiveView

    def mount(_p, _s, socket), do: {:ok, socket}

    def handle_event("go", _params, socket) do
      sup = Argus.Test.Soundness.UnsafeInput.Children.TwiceSup
      worker = Argus.Test.Soundness.UnsafeInput.Children.Worker
      {:ok, pid} = DynamicSupervisor.start_child(sup, worker)
      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
      {:ok, _other} = DynamicSupervisor.start_child(sup, worker)
      {:noreply, socket}
    end

    def render(assigns), do: assigns
  end
end
