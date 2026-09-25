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

  defmodule NoprocLogged do
    @moduledoc false
    # The same catch with a body the compiler gives lines: what a span
    # from the call through the catch is drawn to.
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
        :exit, {:noproc, _} ->
          send(self(), :parent_gone)
          {:error, :noproc}
      end
    end
  end

  defmodule NoprocThenMore do
    @moduledoc false
    # The same catch, not in tail position: the handler runs on into the
    # code after the try, which is not the catch's and not the span's.
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
      result =
        try do
          GenServer.call(parent, {:child_mount, self()})
        catch
          :exit, {:noproc, _} ->
            send(self(), :parent_gone)
            {:error, :noproc}
        end

      send(self(), {:synced, result})
      result
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

  defmodule NoprocAndAnyTuple do
    @moduledoc false
    # brod's safe_gen_call: `exit:{noproc, _}` beside `exit:{Reason, _}`,
    # which takes every tuple reason, `{:shutdown, _}` among them.
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
        :exit, {:noproc, _} -> {:error, :client_down}
        :exit, {reason, _} -> {:error, {:client_down, reason}}
      end
    end
  end

  defmodule NoprocAndNamedTuple do
    @moduledoc false
    # A second clause that takes a tuple by its tag is not every tuple:
    # {:timeout, _} beside {:noproc, _} still leaves {:shutdown, _} out.
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
        :exit, {:noproc, _} -> {:error, :client_down}
        :exit, {:timeout, _} -> {:error, :timeout}
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
