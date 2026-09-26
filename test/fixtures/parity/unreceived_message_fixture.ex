defmodule Argus.Test.Fixtures.UnreceivedMessage do
  @moduledoc """
  Fixtures for `mailbox.unreceived_message`: a message sent to a spawned
  process whose receive has no clause for it. The positive routes the pid
  through a parameter, so no name in the sending function says where the
  message goes; the quiet neighbours send what the receive takes, or cannot
  be judged.
  """

  defmodule Shop do
    @moduledoc "The cart is reached by name, the audit log through a parameter; the log takes only :paid."
    alias Argus.Test.Fixtures.UnreceivedMessage.{Audit, Cart}

    def start do
      cart = spawn(Cart, :loop, [])
      Process.register(cart, :cart)
      audit = spawn(Audit, :loop, [])
      checkout(audit)
    end

    def checkout(log) do
      send(:cart, :checkout)
      send(log, :checked_out)
    end
  end

  defmodule Cart do
    @moduledoc false
    def loop do
      receive do
        :checkout -> loop()
      end
    end
  end

  defmodule Audit do
    @moduledoc false
    def loop do
      receive do
        :paid -> loop()
      end
    end
  end

  defmodule Tagged do
    @moduledoc "A tuple message to a loop that takes only atoms is never taken either."
    def start do
      pid = spawn(__MODULE__, :loop, [])
      send(pid, {:job, 1})
    end

    def loop do
      receive do
        :stop -> :ok
      end
    end
  end

  # ── Quiet neighbours ─────────────────────────────────────────────

  defmodule Taken do
    @moduledoc "The message is one the receive takes."
    def start do
      pid = spawn(__MODULE__, :loop, [])
      send(pid, :tick)
    end

    def loop do
      receive do
        :tick -> loop()
      end
    end
  end

  defmodule CatchAll do
    @moduledoc "A clause that is not an atom takes anything."
    def start do
      pid = spawn(__MODULE__, :loop, [])
      send(pid, :anything)
    end

    def loop do
      receive do
        msg -> {:got, msg}
      end
    end
  end

  defmodule Helper do
    @moduledoc "The receive is in a helper the spawned function calls: not judged."
    def start do
      pid = spawn(__MODULE__, :run, [])
      send(pid, :unknown)
    end

    def run, do: wait()

    def wait do
      receive do
        :tick -> :ok
      end
    end
  end

  defmodule Variable do
    @moduledoc "The message is not a literal."
    def start(msg) do
      pid = spawn(__MODULE__, :loop, [])
      send(pid, msg)
    end

    def loop do
      receive do
        :tick -> loop()
      end
    end
  end

  defmodule Server do
    @moduledoc "The target is a GenServer: a message it has no clause for is unhandled_info's."
    use GenServer

    def start do
      {:ok, pid} = GenServer.start_link(__MODULE__, nil)
      send(pid, :unexpected)
    end

    @impl true
    def init(nil), do: {:ok, nil}
  end
end
