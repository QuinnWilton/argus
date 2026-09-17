defmodule Argus.Test.Fixtures.CatchShapes do
  @moduledoc false

  defmodule NoprocOnly do
    @moduledoc false
    # phoenix_live_view#4359: the parent stopping mid-call arrives as
    # {:shutdown, _}, which this catch does not cover.
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_info(:sync, parent) do
      _ = sync_with_parent(parent)
      {:noreply, parent}
    end

    defp sync_with_parent(parent) do
      try do
        GenServer.call(parent, {:child_mount, self()})
      catch
        :exit, {:noproc, _} -> {:error, :noproc}
      end
    end
  end

  defmodule NoprocAndShutdown do
    @moduledoc false
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_info(:sync, parent) do
      _ = sync_with_parent(parent)
      {:noreply, parent}
    end

    defp sync_with_parent(parent) do
      try do
        GenServer.call(parent, {:child_mount, self()})
      catch
        :exit, {:noproc, _} -> {:error, :noproc}
        :exit, {:shutdown, _} -> {:error, :shutdown}
      end
    end
  end

  defmodule AnyExit do
    @moduledoc false
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_info(:sync, parent) do
      _ = sync_with_parent(parent)
      {:noreply, parent}
    end

    defp sync_with_parent(parent) do
      try do
        GenServer.call(parent, {:child_mount, self()})
      catch
        :exit, reason -> {:error, reason}
      end
    end
  end

  defmodule Erpc do
    @moduledoc false

    # nebulex#140: the remote exception is unwrapped; a transport failure
    # ({:erpc, :noconnection}, {:erpc, :timeout}) is a CaseClauseError.
    def partial(node, mod, fun, args) do
      :erpc.call(node, mod, fun, args, 5000)
    rescue
      e in ErlangError ->
        case e.original do
          {:exception, %{__exception__: true} = original, _} -> reraise original, __STACKTRACE__
          {:exception, original, _} -> :erlang.raise(:error, original, __STACKTRACE__)
        end
    end

    def total(node, mod, fun, args) do
      :erpc.call(node, mod, fun, args, 5000)
    rescue
      e in ErlangError ->
        case e.original do
          {:exception, %{__exception__: true} = original, _} -> reraise original, __STACKTRACE__
          {:exception, original, _} -> :erlang.raise(:error, original, __STACKTRACE__)
          other -> {:error, other}
        end
    end
  end
end
