defmodule Argus.Test.Fixtures.MailboxApproximated do
  @moduledoc """
  Sends whose target is one of two servers of different modules, and a
  cast a server makes to itself by its registered name: what the
  mailbox analysis makes of targets the points-to stage resolved
  field-sensitively, and of the same targets resolved
  field-insensitively.
  """

  defmodule Left do
    @moduledoc "Takes :left alone."
    use GenServer

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_info(:left, s), do: {:noreply, s}
  end

  defmodule Right do
    @moduledoc "Takes :right alone."
    use GenServer

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_info(:right, s), do: {:noreply, s}
  end

  defmodule Sender do
    @moduledoc """
    Starts Left or Right and sends it :left: Right, which takes :right
    alone, crashes on it.
    """
    alias Argus.Test.Fixtures.MailboxApproximated.{Left, Right}

    def run(left?) do
      {:ok, target} =
        if left?,
          do: GenServer.start_link(Left, :ok),
          else: GenServer.start_link(Right, :ok)

      send(target, :left)
    end
  end

  defmodule Self do
    @moduledoc "Casts itself, by its registered name, a tag it has no clause for."
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def poke, do: GenServer.cast(__MODULE__, :poke)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_cast(:other, s), do: {:noreply, s}
  end
end
