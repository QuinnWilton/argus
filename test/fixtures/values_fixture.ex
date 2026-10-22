defmodule Argus.Test.Fixtures.Values do
  @moduledoc """
  Literals handed through chains of private helpers, through a helper's
  result and into a process start, and the ways a parameter's set stops
  being complete: an export, a computed argument, a captured fun, a
  result handed on.
  """

  defmodule Chain do
    @moduledoc "Two callers hand a table name through two wrappers."
    def run_a, do: wrap(:alpha)
    def run_b, do: wrap(:beta)

    defp wrap(name), do: inner(name, 1)
    defp inner(name, key), do: deepest(name, key)
    defp deepest(name, key), do: :ets.lookup(name, key)
  end

  defmodule Exported do
    @moduledoc "An export's parameter is anyone's: its set is never complete."
    def run, do: lookup(:gamma)
    def lookup(name), do: hidden(name)
    defp hidden(name), do: :ets.lookup(name, 1)
  end

  defmodule Computed do
    @moduledoc "A caller hands a computed value beside a literal."
    def run(prefix), do: {take(:delta), take(String.to_atom(prefix))}
    defp take(name), do: :ets.lookup(name, 1)
  end

  defmodule Captured do
    @moduledoc "A function captured as a fun is called by whoever holds the fun."
    def run(names), do: {apply_each(names), read(:epsilon)}
    defp apply_each(names), do: Enum.map(names, &read/1)
    defp read(name), do: :ets.lookup(name, 1)
  end

  defmodule Fifth do
    @moduledoc "Every argument is followed, the fifth too."
    def run, do: five(:a, :b, :c, :d, :e)
    defp five(a, b, c, d, e), do: {a, b, c, d, e}
  end

  defmodule Results do
    @moduledoc "A helper's result holds what it returns, at each call."
    def run, do: {take(name()), take(same(:eta))}
    defp name, do: :zeta
    defp same(value), do: value
    defp take(name), do: :ets.lookup(name, 1)
  end

  defmodule Started do
    @moduledoc "A start hands its argument to init/1."
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, :theta)
    @impl true
    def init(table), do: {:ok, table}
  end
end
