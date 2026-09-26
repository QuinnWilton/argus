defmodule Argus.Test.Fixtures.Consistency do
  @moduledoc """
  Fixtures for `failure`'s consistency rule: a call site that breaks with
  how the program's other sites treat the same callee.

  `DynamicSupervisor.start_child/2` and `GenServer.call/2` stand in for
  any process API. The counts are the point: three agreeing sites make a
  belief, and a deviant must be a quarter or fewer of the population.
  """

  defmodule DeviantIgnore do
    @moduledoc "Five sites match start_child's result; one discards it."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def d(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def e(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def f(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule DeviantBare do
    @moduledoc "Four sites guard GenServer.call with a try; one calls it bare."

    def a(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def b(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def c(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def d(s) do
      GenServer.call(s, :ping)
    catch
      :exit, _ -> :down
    end

    def e(s), do: GenServer.call(s, :ping)
  end

  defmodule WeakBelief do
    @moduledoc "Two sites check, one ignores: not enough agreement to call it a convention."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def c(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule NoMajority do
    @moduledoc "Three check, three ignore: a convention either way."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))

    def d(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    def e(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    def f(sup, spec) do
      DynamicSupervisor.start_child(sup, spec)
      :ok
    end

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end

  defmodule OutsideScope do
    @moduledoc "File.write is not a process API: five checked and one ignored say nothing here."
    def a(p, d), do: check(File.write(p, d))
    def b(p, d), do: check(File.write(p, d))
    def c(p, d), do: check(File.write(p, d))
    def d(p, d), do: check(File.write(p, d))
    def e(p, d), do: check(File.write(p, d))

    def f(p, d) do
      File.write(p, d)
      :ok
    end

    defp check(:ok), do: :ok
    defp check({:error, _}), do: :error
  end

  defmodule TailReturns do
    @moduledoc "Sites that return the result hand the question to their callers; they are not deviants."
    def a(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def b(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def c(sup, spec), do: check(DynamicSupervisor.start_child(sup, spec))
    def d(sup, spec), do: DynamicSupervisor.start_child(sup, spec)
    def e(sup, spec), do: DynamicSupervisor.start_child(sup, spec)

    defp check({:ok, pid}), do: pid
    defp check({:error, _}), do: nil
  end
end
