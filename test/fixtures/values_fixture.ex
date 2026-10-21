defmodule Argus.Test.Fixtures.Values do
  @moduledoc """
  Literals handed through chains of private helpers, and the ways a
  parameter's set stops being complete: an export, a computed argument,
  a captured fun, an argument past the fourth.
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
    @moduledoc "call_arg resolves four arguments; the fifth is unknown."
    def run, do: five(:a, :b, :c, :d, :e)
    defp five(a, b, c, d, e), do: {a, b, c, d, e}
  end
end
