defmodule Argus.Test.Fixtures.SidePaths do
  @moduledoc """
  Fixtures for the waits a server does not make: a call into the logger
  (whose own servers answer the logger, never the program), and an
  :infinity hop into a server that answers at once.
  """

  defmodule Logs do
    @moduledoc "Logs from handle_call, as OTP's global and supervisor do."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def work, do: GenServer.call(__MODULE__, :work)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:work, _from, state) do
      :logger.error(~c"work failed")
      {:reply, :ok, state}
    end
  end

  defmodule CallsLogs do
    @moduledoc "Calls Logs from its own handle_call: one hop, then the logger."
    use GenServer

    alias Argus.Test.Fixtures.SidePaths.Logs

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:relay, _from, state), do: {:reply, Logs.work(), state}
  end

  defmodule StopsProxy do
    @moduledoc "Phoenix's CodeReloader: stops a proxy with :infinity; the proxy's clause only replies."
    use GenServer

    alias Argus.Test.Fixtures.SidePaths.Proxy

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:reload, _from, state) do
      {:ok, proxy} = Proxy.start()
      {:reply, Proxy.stop(proxy), state}
    end
  end

  defmodule Proxy do
    @moduledoc false
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])
    def stop(proxy), do: GenServer.call(proxy, :stop, :infinity)

    @impl true
    def init(output), do: {:ok, output}

    @impl true
    def handle_call(:stop, _from, output), do: {:stop, :normal, Enum.reverse(output), output}
  end

  defmodule AsksWorker do
    @moduledoc "Waits with :infinity on a worker that itself waits: a chain of waits."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:ask, _from, state) do
      {:reply, GenServer.call(Argus.Test.Fixtures.SidePaths.Worker, :work, :infinity), state}
    end
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:work, _from, state) do
      receive do
        {:done, result} -> {:reply, result, state}
      end
    end
  end
end
