defmodule Argus.Test.Fixtures.InitRecv do
  @moduledoc false

  defmodule Blocking do
    @moduledoc false
    # postgrex#746: a handshake in init/1 that waits on the socket forever.
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock) do
      case handshake(sock) do
        {:ok, greeting} -> {:ok, %{sock: sock, greeting: greeting}}
        {:error, reason} -> {:stop, reason}
      end
    end

    defp handshake(sock), do: msg_recv(sock, :infinity)

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule Bounded do
    @moduledoc false
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock) do
      case msg_recv(sock, 5000) do
        {:ok, greeting} -> {:ok, %{sock: sock, greeting: greeting}}
        {:error, reason} -> {:stop, reason}
      end
    end

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule Later do
    @moduledoc false
    use GenServer

    def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

    @impl true
    def init(sock), do: {:ok, sock}

    @impl true
    def handle_info(:read, sock) do
      _ = msg_recv(sock, :infinity)
      {:noreply, sock}
    end

    defp msg_recv(sock, timeout) do
      case :gen_tcp.recv(sock, 0, timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
