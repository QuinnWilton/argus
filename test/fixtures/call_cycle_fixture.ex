defmodule Argus.Test.Fixtures.CycleServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_b(server), do: GenServer.call(server, :ask_b)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_b, _from, state) do
    # Sync-calls CycleServerB — creates half of a deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerB, :ping)
    {:reply, result, state}
  end
end

defmodule Argus.Test.Fixtures.CycleServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_a(server), do: GenServer.call(server, :ask_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_a, _from, state) do
    # Sync-calls CycleServerA — completes the deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerA, :ping)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end
end

defmodule Argus.Test.Fixtures.CallCycle do
  @moduledoc """
  Shapes that look like a synchronous call cycle between two modules, and
  the ones beside them that are: two modules call each other only when
  their processes do.
  """

  # ── A buffer module and its thin wrappers (Plausible's write buffers) ──

  defmodule WriteBuffer do
    @moduledoc "One server module; each wrapper below starts an instance under its own name."
    use GenServer

    def child_spec(opts), do: %{id: opts[:name], start: {__MODULE__, :start_link, [opts]}}

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def insert(server, row), do: GenServer.cast(server, {:insert, row})
    def flush(server), do: GenServer.call(server, :flush, :infinity)

    @impl true
    def init(opts), do: {:ok, %{name: opts[:name], rows: []}}

    @impl true
    def handle_cast({:insert, row}, state), do: {:noreply, %{state | rows: [row | state.rows]}}

    @impl true
    def handle_call(:flush, _from, state), do: {:reply, :ok, %{state | rows: []}}
  end

  defmodule EventBuffer do
    @moduledoc "Names a WriteBuffer after itself; runs no process of its own."
    alias Argus.Test.Fixtures.CallCycle.WriteBuffer

    def child_spec(opts), do: WriteBuffer.child_spec(Keyword.put(opts, :name, __MODULE__))
    def insert(row), do: WriteBuffer.insert(__MODULE__, row)
    def flush, do: WriteBuffer.flush(__MODULE__)
  end

  defmodule SessionBuffer do
    @moduledoc false
    alias Argus.Test.Fixtures.CallCycle.WriteBuffer

    def child_spec(opts), do: WriteBuffer.child_spec(Keyword.put(opts, :name, __MODULE__))
    def insert(row), do: WriteBuffer.insert(__MODULE__, row)
    def flush, do: WriteBuffer.flush(__MODULE__)
  end

  defmodule Buffers do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.CallCycle.{EventBuffer, SessionBuffer}

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts), do: Supervisor.init([EventBuffer, SessionBuffer], strategy: :one_for_one)
  end

  # ── A client function in a server module (klife's Producer) ──────────

  defmodule Producer do
    @moduledoc """
    produce/1 is a client function: it runs in whichever process calls it.
    Producer's own process only answers :new_epoch.
    """
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Batcher

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def produce(records), do: Batcher.produce(records)
    def new_epoch, do: GenServer.call(__MODULE__, :new_epoch)

    @impl true
    def init(:ok), do: {:ok, 0}

    @impl true
    def handle_call(:new_epoch, _from, epoch), do: {:reply, epoch + 1, epoch + 1}
  end

  defmodule Batcher do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Producer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def produce(records), do: GenServer.call(__MODULE__, {:produce, records})

    @impl true
    def init(:ok), do: {:ok, []}

    @impl true
    def handle_call({:produce, records}, _from, state),
      do: {:reply, {:ok, Producer.new_epoch()}, records ++ state}
  end

  # ── A task the server waits for ──────────────────────────────────────

  defmodule Awaiter do
    @moduledoc """
    Waits for a task that calls Awaited, whose handler calls Awaiter
    back: Awaiter is blocked in Task.await, so the cycle is real.
    """
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Awaited

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def ask, do: GenServer.call(__MODULE__, :ask)
    def ping, do: GenServer.call(__MODULE__, :ping)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ask, _from, s) do
      answer = Task.async(fn -> Awaited.get() end) |> Task.await()
      {:reply, answer, s}
    end

    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  end

  defmodule Awaited do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Awaiter

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def get, do: GenServer.call(__MODULE__, :get)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:get, _from, s), do: {:reply, Awaiter.ping(), s}
  end

  # ── A wait made only on the way up (LiveView's upload channel) ───────

  defmodule View do
    @moduledoc """
    Learns an upload channel's pid from the channel's own registration,
    answers it at once, and calls the channel only later.
    """
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.UploadChannel

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    def register_upload(pid, ref),
      do: GenServer.call(pid, {:register_upload, %{channel_pid: self(), ref: ref}})

    @impl true
    def init(:ok), do: {:ok, %{uploads: %{}}}

    @impl true
    def handle_call({:register_upload, %{channel_pid: channel, ref: ref}}, from, state) do
      GenServer.reply(from, :ok)
      {:noreply, %{state | uploads: Map.put(state.uploads, ref, channel)}}
    end

    @impl true
    def handle_info({:cancel, ref}, state) do
      case Map.fetch(state.uploads, ref) do
        {:ok, channel} -> UploadChannel.cancel(channel)
        :error -> :ok
      end

      {:noreply, state}
    end
  end

  defmodule UploadChannel do
    @moduledoc "Calls the view from join/3 alone; nothing names it."
    @behaviour Phoenix.Channel

    alias Argus.Test.Fixtures.CallCycle.View

    def cancel(pid), do: GenServer.call(pid, :cancel)

    def join(_topic, %{"view" => view, "ref" => ref}, socket) do
      :ok = View.register_upload(view, ref)
      {:ok, socket}
    end

    def handle_call(:cancel, _from, socket), do: {:reply, :ok, socket}
  end

  # The same from init/1: an unnamed worker registers with its manager,
  # which answers and calls the worker only later.
  defmodule Manager do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Worker

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def register(worker), do: GenServer.call(__MODULE__, {:register, worker})

    @impl true
    def init(:ok), do: {:ok, []}

    @impl true
    def handle_call({:register, worker}, _from, workers), do: {:reply, :ok, [worker | workers]}

    @impl true
    def handle_info(:poll, workers) do
      Enum.each(workers, &Worker.status/1)
      {:noreply, workers}
    end
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Manager

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
    def status(pid), do: GenServer.call(pid, :status)

    @impl true
    def init(arg) do
      :ok = Manager.register(self())
      {:ok, arg}
    end

    @impl true
    def handle_call(:status, _from, s), do: {:reply, :ok, s}
  end

  # A worker registered under a name while its init runs: its manager can
  # call it by name before init returns, and both wait.
  defmodule NamedManager do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.NamedWorker

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def register, do: GenServer.call(__MODULE__, :register)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:register, _from, s), do: {:reply, :ok, s}

    @impl true
    def handle_info(:poll, s) do
      NamedWorker.status()
      {:noreply, s}
    end
  end

  defmodule NamedWorker do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.NamedManager

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)
    def status, do: GenServer.call(__MODULE__, :status)

    @impl true
    def init(arg) do
      :ok = NamedManager.register()
      {:ok, arg}
    end

    @impl true
    def handle_call(:status, _from, s), do: {:reply, :ok, s}
  end

  # A peer that answers the start's own request by calling the starting
  # process: the start deadlocks every time.
  defmodule Greeter do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Joiner

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def hello(pid), do: GenServer.call(__MODULE__, {:hello, pid})

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call({:hello, pid}, _from, s), do: {:reply, Joiner.name(pid), s}
  end

  defmodule Joiner do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.CallCycle.Greeter

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
    def name(pid), do: GenServer.call(pid, :name)

    @impl true
    def init(arg) do
      Greeter.hello(self())
      {:ok, arg}
    end

    @impl true
    def handle_call(:name, _from, s), do: {:reply, :joiner, s}
  end

  defmodule ExtensionsHub do
    @moduledoc """
    nerves_hub_link's Extensions: a detach pushes to the socket through
    its client API, from inside a comprehension's closure.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def init(state), do: {:ok, state}

    def offer(advertisement), do: GenServer.call(__MODULE__, {:offer, advertisement})

    def handle_call({:offer, _ad}, _from, state), do: {:reply, :ok, state}

    def handle_cast({:detach, extensions}, state) do
      state =
        for extension <- extensions, reduce: state do
          acc ->
            _ = Argus.Test.Fixtures.CallCycle.HubSocket.push("#{extension}:detached")
            Map.put(acc, extension, false)
        end

      {:noreply, state}
    end
  end

  defmodule HubSocket do
    @moduledoc "nerves_hub_link's Socket: the extensions topic asks for an offer."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def init(state), do: {:ok, state}

    def push(event), do: GenServer.call(__MODULE__, {:push, event})

    def handle_call({:push, _event}, _from, state), do: {:reply, :ok, state}

    def handle_info({:join, payload}, state) do
      _ = Argus.Test.Fixtures.CallCycle.ExtensionsHub.offer(payload)
      {:noreply, state}
    end
  end
end
