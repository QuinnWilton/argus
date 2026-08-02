defmodule Argus.Test.Fixtures.Purity do
  @moduledoc """
  Fixtures for the purity analysis.

  Grouped by what the analysis has to conclude: verified, violated, or
  unprovable. The unprovable group is the one that matters — a purity claim
  is a claim about every execution, so a call the analysis cannot follow has
  to be reported as such rather than assumed harmless.
  """

  defmodule Clean do
    @moduledoc "Genuinely pure: arithmetic, matching, and other pure calls."
    use Argus.Purity

    @pure true
    def add(a, b), do: a + b

    @pure true
    def scale(list, factor), do: Enum.map(list, fn x -> x * factor end)

    @pure true
    def total(list), do: sum(list, 0)

    # Not declared, but pure — reached from a declared-pure function, so the
    # analysis has to follow into it rather than stop at the declaration.
    defp sum([], acc), do: acc
    defp sum([h | t], acc), do: sum(t, acc + h)

    @pure true
    def bang!(x) when is_integer(x), do: x
    def bang!(_), do: raise(ArgumentError, "not an integer")
  end

  defmodule DirectEffects do
    @moduledoc "Declared pure, effect in the function itself."
    use Argus.Purity

    @pure true
    def logs(x) do
      IO.puts("value: #{inspect(x)}")
      x
    end

    @pure true
    def sends(pid, msg) do
      send(pid, msg)
      :ok
    end

    @pure true
    def reads_clock, do: System.monotonic_time()

    @pure true
    def randomises, do: :rand.uniform(100)

    @pure true
    def process_dict(x) do
      Process.put(:cached, x)
      x
    end
  end

  defmodule IndirectEffects do
    @moduledoc "Declared pure, effect one or more calls away."
    use Argus.Purity

    @pure true
    def outer(x), do: middle(x)
    defp middle(x), do: inner(x)
    defp inner(x), do: IO.inspect(x)
  end

  defmodule EffectfulClosure do
    @moduledoc """
    Declared pure, effect inside a closure the function itself builds.

    The compiler lifts the lambda to its own function and argus records a
    closure_def edge, so the existing call graph reaches it — no special
    handling needed, which is worth pinning.
    """
    use Argus.Purity

    @pure true
    def each(list), do: Enum.each(list, fn x -> IO.puts(x) end)
  end

  defmodule Unprovable do
    @moduledoc "Declared pure, but contains a call the graph cannot follow."
    use Argus.Purity

    @pure true
    def applies(f, x), do: f.(x)

    @pure true
    def dispatches(m, f, a), do: apply(m, f, a)
  end

  defmodule HigherOrder do
    @moduledoc """
    A declared-pure function that calls the fun it is given. Its purity is
    the CALLER's obligation, so the contract is checked at the call site.
    """
    use Argus.Purity

    @pure true
    def transform(list, f), do: Enum.map(list, fn x -> f.(x) end)
  end

  defmodule GoodCaller do
    @moduledoc "Hands over a pure closure — nothing to report."
    def double(list), do: HigherOrder.transform(list, fn x -> x * 2 end)
  end

  defmodule BadCaller do
    @moduledoc "Hands over a closure that logs. The contract breaks here."
    def trace(list), do: HigherOrder.transform(list, fn x -> IO.puts(x) end)
  end

  defmodule Undeclared do
    @moduledoc "Effects everywhere, but claims nothing — must stay silent."
    def shout(x), do: IO.puts(x)
    def store(k, v), do: :persistent_term.put(k, v)
  end
end
