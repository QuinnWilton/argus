defmodule Argus.Test.Fixtures.Sockets do
  @moduledoc """
  Fixtures for sockets a server holds.

  `mailbox.unhandled_info`'s "socket" source: a server that makes a TCP or
  TLS socket active in its own process is sent the socket's close,
  `{:tcp_closed, s}` or `{:ssl_closed, s}`, and needs a clause for it.
  Each quiet shape sits beside the positive it differs from in one
  premise: the clause is there, the socket is passive, the socket is
  handed to another process, the catch-all hands the message on, a
  receive in the callback takes it, or the socket is a UDP one.

  `blocking.unbounded_wait`'s "socket" kind: a socket call with no
  timeout on a callback's own stack. Its quiet shapes pass a timeout,
  wait only in init/1 (startup's), or wait in a task.
  """

  # ── Closes ───────────────────────────────────────────────────────────

  defmodule ActiveTcp do
    @moduledoc "Connects with active: true and takes its data, not its close."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port), do: {:ok, %{port: port, socket: nil, buffer: ""}, {:continue, :connect}}

    @impl true
    def handle_continue(:connect, state) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", state.port, [:binary, active: true])
      {:noreply, %{state | socket: socket}}
    end

    @impl true
    def handle_info({:tcp, _socket, data}, state),
      do: {:noreply, %{state | buffer: state.buffer <> data}}
  end

  defmodule ActiveTcpHandled do
    @moduledoc "The same server, with a clause for the close: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port), do: {:ok, %{port: port, socket: nil, buffer: ""}, {:continue, :connect}}

    @impl true
    def handle_continue(:connect, state) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", state.port, [:binary, active: true])
      {:noreply, %{state | socket: socket}}
    end

    @impl true
    def handle_info({:tcp, _socket, data}, state),
      do: {:noreply, %{state | buffer: state.buffer <> data}}

    def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  end

  defmodule PassiveTcp do
    @moduledoc "The same connect with active: false, read with a timed recv: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port), do: {:ok, %{port: port, socket: nil}, {:continue, :connect}}

    @impl true
    def handle_continue(:connect, state) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", state.port, [:binary, active: false])
      {:noreply, %{state | socket: socket}}
    end

    @impl true
    def handle_call(:read, _from, state),
      do: {:reply, :gen_tcp.recv(state.socket, 0, 5_000), state}

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule DefaultActive do
    @moduledoc "Connects with options that leave :active out, which is active: true."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line])
      {:ok, %{socket: socket, lines: []}}
    end

    @impl true
    def handle_info({:tcp, _socket, line}, state),
      do: {:noreply, %{state | lines: [line | state.lines]}}
  end

  defmodule TlsTakesTcpClose do
    @moduledoc """
    A TLS client that takes the TCP close and not the TLS one (cqerl,
    mongodb): a TLS socket's end is {:ssl_closed, _}.
    """
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :ssl.connect(~c"localhost", port, active: :once, verify: :verify_peer)
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_info({:ssl, socket, _data}, state) do
      :ok = :ssl.setopts(socket, active: :once)
      {:noreply, state}
    end

    def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  end

  defmodule TlsTakesBoth do
    @moduledoc "The same client with the TLS close: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :ssl.connect(~c"localhost", port, active: :once, verify: :verify_peer)
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_info({:ssl, socket, _data}, state) do
      :ok = :ssl.setopts(socket, active: :once)
      {:noreply, state}
    end

    def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
    def handle_info({:ssl_closed, _socket}, state), do: {:stop, :normal, state}
  end

  defmodule Wrapped do
    @moduledoc """
    kafka_ex's shape: a socket module of the program's own, over TCP or
    TLS, and a client that makes its socket active through it.
    """

    defmodule Socket do
      @moduledoc "Either transport, behind one API."
      defstruct [:socket, ssl: false]

      def create(host, port, opts, true) do
        {:ok, socket} = :ssl.connect(host, port, opts)
        %__MODULE__{socket: socket, ssl: true}
      end

      def create(host, port, opts, false) do
        {:ok, socket} = :gen_tcp.connect(host, port, opts)
        %__MODULE__{socket: socket}
      end

      def setopts(%__MODULE__{ssl: true, socket: socket}, opts), do: :ssl.setopts(socket, opts)
      def setopts(%__MODULE__{socket: socket}, opts), do: :inet.setopts(socket, opts)
    end

    defmodule Client do
      @moduledoc "Reads a reply passively, then leaves the socket active."
      use GenServer

      alias Argus.Test.Fixtures.Sockets.Wrapped.Socket

      def start_link(ssl?), do: GenServer.start_link(__MODULE__, ssl?)

      @impl true
      def init(ssl?) do
        socket = Socket.create(~c"localhost", 9092, [:binary, {:active, false}], ssl?)
        {:ok, %{socket: socket}}
      end

      @impl true
      def handle_call({:request, data}, _from, state) do
        :ok = Socket.setopts(state.socket, [:binary, {:packet, 4}, {:active, false}])
        reply = request(state.socket, data)
        :ok = Socket.setopts(state.socket, [:binary, {:packet, 4}, {:active, true}])
        {:reply, reply, state}
      end

      @impl true
      def handle_info(:update_metadata, state), do: {:noreply, state}

      defp request(%Socket{ssl: true, socket: socket}, data) do
        :ok = :ssl.send(socket, data)
        :ssl.recv(socket, 0, 5_000)
      end

      defp request(%Socket{socket: socket}, data) do
        :ok = :gen_tcp.send(socket, data)
        :gen_tcp.recv(socket, 0, 5_000)
      end
    end

    defmodule HandledClient do
      @moduledoc "The same client with both closes: quiet."
      use GenServer

      alias Argus.Test.Fixtures.Sockets.Wrapped.Socket

      def start_link(ssl?), do: GenServer.start_link(__MODULE__, ssl?)

      @impl true
      def init(ssl?) do
        socket = Socket.create(~c"localhost", 9092, [:binary, {:active, false}], ssl?)
        {:ok, %{socket: socket}}
      end

      @impl true
      def handle_call(:arm, _from, state) do
        :ok = Socket.setopts(state.socket, [:binary, {:packet, 4}, {:active, true}])
        {:reply, :ok, state}
      end

      @impl true
      def handle_info(:update_metadata, state), do: {:noreply, state}
      def handle_info({:tcp_closed, _socket}, state), do: {:noreply, %{state | socket: nil}}
      def handle_info({:ssl_closed, _socket}, state), do: {:noreply, %{state | socket: nil}}
    end
  end

  defmodule LogsTheRest do
    @moduledoc "The close falls into a catch-all that only logs it: the server keeps a dead socket."
    use GenServer

    require Logger

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: :once])
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_info({:tcp, socket, _data}, state) do
      :ok = :inet.setopts(socket, active: :once)
      {:noreply, state}
    end

    def handle_info(message, state) do
      Logger.warning("unexpected message: #{inspect(message)}")
      {:noreply, state}
    end
  end

  defmodule HandsTheRestOn do
    @moduledoc "The catch-all hands every message to the protocol, which may take the close: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: :once])
      {:ok, %{socket: socket, events: []}}
    end

    @impl true
    def handle_info({:tcp, socket, _data}, state) do
      :ok = :inet.setopts(socket, active: :once)
      {:noreply, state}
    end

    def handle_info(message, state), do: {:noreply, %{state | events: [message | state.events]}}
  end

  defmodule HandsOff do
    @moduledoc "Connects active, then hands the socket to a worker: its messages go there. Quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port), do: {:ok, %{port: port}}

    @impl true
    def handle_call({:connect, worker}, _from, state) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", state.port, [:binary, active: true])
      :ok = :gen_tcp.controlling_process(socket, worker)
      {:reply, :ok, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule WaitsForIt do
    @moduledoc "Arms one packet and waits for it, close included, in the callback: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_call(:next, _from, %{socket: socket} = state) do
      :ok = :inet.setopts(socket, active: :once)

      reply =
        receive do
          {:tcp, ^socket, data} -> {:ok, data}
          {:tcp_closed, ^socket} -> {:error, :closed}
        after
          5_000 -> {:error, :timeout}
        end

      {:reply, reply, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule InetTcp do
    @moduledoc ":inet.setopts on the TCP socket the server connected: its close is {:tcp_closed, _}."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_info(:arm, state) do
      :ok = :inet.setopts(state.socket, active: :once)
      {:noreply, state}
    end

    def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}
  end

  defmodule InetUdp do
    @moduledoc "The same :inet.setopts on a UDP socket, which has no close: quiet."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_udp.open(port, [:binary, active: false])
      {:ok, %{socket: socket}}
    end

    @impl true
    def handle_info(:arm, state) do
      :ok = :inet.setopts(state.socket, active: :once)
      {:noreply, state}
    end

    def handle_info({:udp, _socket, _ip, _port, _data}, state), do: {:noreply, state}
  end

  defmodule ThroughTransport do
    @moduledoc "A transport module in the state sets active: the TCP socket it connected closes."
    use GenServer

    def start_link(port), do: GenServer.start_link(__MODULE__, port)

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
      {:ok, %{socket: socket, transport: :inet}}
    end

    @impl true
    def handle_info(:arm, %{transport: transport, socket: socket} = state) do
      :ok = transport.setopts(socket, active: :once)
      {:noreply, state}
    end

    def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}
  end

  defmodule StatemTcp do
    @moduledoc "A gen_statem whose states take the data and have no :info catch-all."
    @behaviour :gen_statem

    def start_link(port), do: :gen_statem.start_link(__MODULE__, port, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: true])
      {:ok, :connected, %{socket: socket}}
    end

    def connected(:info, {:tcp, _socket, _data}, data), do: {:keep_state, data}
    def connected({:call, from}, :ping, data), do: {:keep_state, data, [{:reply, from, :pong}]}
  end

  defmodule StatemHandsOn do
    @moduledoc """
    The same machine, whose :info clause takes any content whatever it
    demands of the data and hands it to the protocol: a catch-all. Quiet.
    """
    @behaviour :gen_statem

    def start_link(port), do: :gen_statem.start_link(__MODULE__, port, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: true])
      {:ok, :connected, %{socket: socket, events: []}}
    end

    def connected(:info, message, %{events: events} = data),
      do: {:keep_state, %{data | events: [message | events]}}

    def connected({:call, from}, :ping, data), do: {:keep_state, data, [{:reply, from, :pong}]}
  end

  defmodule OneStateHandsOn do
    @moduledoc """
    Postgrex's ReplicationConnection: handle_event/4 takes every :info in
    its one state, `handle_event(:info, msg, @state, s)`, and hands it on.
    Quiet.
    """
    @behaviour :gen_statem

    @state :no_state

    def start_link(port), do: :gen_statem.start_link(__MODULE__, port, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(port) do
      {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: true])
      {:ok, @state, %{socket: socket, events: []}}
    end

    @impl true
    def handle_event(:info, message, @state, %{events: events} = data),
      do: {:keep_state, %{data | events: [message | events]}}

    def handle_event({:call, from}, :ping, @state, data),
      do: {:keep_state, data, [{:reply, from, :pong}]}
  end

  # ── Waits ────────────────────────────────────────────────────────────

  defmodule RecvInCallback do
    @moduledoc "Reads its socket with :gen_tcp.recv/2 from handle_info/2: no timeout."
    use GenServer

    def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

    @impl true
    def init(socket), do: {:ok, %{socket: socket}}

    @impl true
    def handle_info(:read, state) do
      {:ok, _data} = :gen_tcp.recv(state.socket, 0)
      send(self(), :read)
      {:noreply, state}
    end
  end

  defmodule RecvBounded do
    @moduledoc "The same read with a timeout: quiet."
    use GenServer

    def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

    @impl true
    def init(socket), do: {:ok, %{socket: socket}}

    @impl true
    def handle_info(:read, state) do
      {:ok, _data} = :gen_tcp.recv(state.socket, 0, 5_000)
      send(self(), :read)
      {:noreply, state}
    end
  end

  defmodule RecvInTask do
    @moduledoc "The same read in a task the callback starts: the task waits, not the server. Quiet."
    use GenServer

    def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

    @impl true
    def init(socket), do: {:ok, %{socket: socket}}

    @impl true
    def handle_info(:read, state) do
      socket = state.socket
      {:ok, _pid} = Task.start(fn -> :gen_tcp.recv(socket, 0) end)
      {:noreply, state}
    end
  end

  defmodule RecvInInit do
    @moduledoc "Reads its greeting in init/1 with no timeout: startup's finding, not blocking's."
    use GenServer

    def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

    @impl true
    def init(socket) do
      {:ok, greeting} = :gen_tcp.recv(socket, 0)
      {:ok, %{socket: socket, greeting: greeting}}
    end
  end

  defmodule ReconnectsInCall do
    @moduledoc "kafka_ex's shape: handle_call reconnects through helpers with :gen_tcp.connect/3."
    use GenServer

    def start_link(host), do: GenServer.start_link(__MODULE__, host)

    @impl true
    def init(host), do: {:ok, %{host: host, socket: nil}}

    @impl true
    def handle_call(:reconnect, _from, state) do
      socket = connect(state.host, 9092)
      {:reply, :ok, %{state | socket: socket}}
    end

    defp connect(host, port) do
      case :gen_tcp.connect(host, port, [:binary, active: false]) do
        {:ok, socket} -> socket
        {:error, _reason} -> nil
      end
    end
  end

  defmodule ReconnectsBounded do
    @moduledoc "The same reconnect with :gen_tcp.connect/4 and a timeout: quiet."
    use GenServer

    def start_link(host), do: GenServer.start_link(__MODULE__, host)

    @impl true
    def init(host), do: {:ok, %{host: host, socket: nil}}

    @impl true
    def handle_call(:reconnect, _from, state) do
      socket = connect(state.host, 9092)
      {:reply, :ok, %{state | socket: socket}}
    end

    defp connect(host, port) do
      case :gen_tcp.connect(host, port, [:binary, active: false], 5_000) do
        {:ok, socket} -> socket
        {:error, _reason} -> nil
      end
    end
  end

  defmodule HandshakeInState do
    @moduledoc "supavisor's shape: a gen_statem upgrades its socket with :ssl.handshake/2 and options."
    @behaviour :gen_statem

    def start_link(socket), do: :gen_statem.start_link(__MODULE__, socket, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(socket), do: {:ok, :exchange, %{socket: socket}}

    @impl true
    def handle_event(:info, :upgrade, :exchange, data) do
      {:ok, tls} = :ssl.handshake(data.socket, certfile: "cert.pem", keyfile: "key.pem")
      {:next_state, :authenticating, %{data | socket: tls}}
    end

    def handle_event(_type, _content, _state, data), do: {:keep_state, data}
  end

  defmodule HandshakeBounded do
    @moduledoc "The same upgrade with :ssl.handshake/3 and a timeout: quiet."
    @behaviour :gen_statem

    def start_link(socket), do: :gen_statem.start_link(__MODULE__, socket, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(socket), do: {:ok, :exchange, %{socket: socket}}

    @impl true
    def handle_event(:info, :upgrade, :exchange, data) do
      {:ok, tls} = :ssl.handshake(data.socket, [certfile: "cert.pem"], 2_500)
      {:next_state, :authenticating, %{data | socket: tls}}
    end

    def handle_event(_type, _content, _state, data), do: {:keep_state, data}
  end

  defmodule InfinityThroughHelper do
    @moduledoc "A helper takes the recv timeout as a parameter, and the callback passes :infinity."
    use GenServer

    def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

    @impl true
    def init(socket), do: {:ok, %{socket: socket}}

    @impl true
    def handle_call(:read, _from, state), do: {:reply, read(state.socket, :infinity), state}

    # Public, so the compiler cannot narrow the parameter to the one value
    # this module passes it.
    def read(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  end
end
