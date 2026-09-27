defmodule Argus.Test.Fixtures.Escape do
  @moduledoc false
  # clientlib/escape.dl's `escapes`: each module's `root` is the function
  # asked about, its `:ets.update_counter/3` raises "badarg" and its
  # `:erpc.call/4` raises "erpc".

  defmodule Bare do
    @moduledoc false
    def root(t), do: :ets.update_counter(t, :k, 1)
  end

  defmodule Rescued do
    @moduledoc false
    def root(t) do
      :ets.update_counter(t, :k, 1)
    rescue
      ArgumentError -> 0
    end
  end

  defmodule RescuesEveryError do
    @moduledoc false
    def root(t) do
      :ets.update_counter(t, :k, 1)
    rescue
      _ -> 0
    end
  end

  defmodule UnrelatedRescue do
    @moduledoc false
    def root(t, payload) do
      n = :ets.update_counter(t, :k, 1)

      try do
        :erlang.binary_to_term(payload)
      rescue
        _ -> n
      end
    end
  end

  defmodule WrongClass do
    @moduledoc false
    def root(t) do
      :ets.update_counter(t, :k, 1)
    rescue
      KeyError -> 0
    end
  end

  defmodule CatchesExit do
    @moduledoc false
    def root(t) do
      :ets.update_counter(t, :k, 1)
    catch
      :exit, _ -> 0
    end
  end

  defmodule Reraises do
    @moduledoc false
    def root(t) do
      :ets.update_counter(t, :k, 1)
    rescue
      e in ArgumentError ->
        :telemetry.execute([:counter, :miss], %{}, %{})
        reraise e, __STACKTRACE__
    end
  end

  defmodule HelperRescue do
    @moduledoc false
    def root(t) do
      bump(t)
    rescue
      ArgumentError -> 0
    end

    defp bump(t), do: :ets.update_counter(t, :k, 1)
  end

  defmodule HelperUnguarded do
    @moduledoc false
    def root(t, payload) do
      n = bump(t)

      try do
        :erlang.binary_to_term(payload)
      rescue
        _ -> n
      end
    end

    defp bump(t), do: :ets.update_counter(t, :k, 1)
  end

  defmodule CallerRescues do
    @moduledoc false
    def entry(t) do
      root(t)
    rescue
      ArgumentError -> 0
    end

    defp root(t), do: :ets.update_counter(t, :k, 1)
  end

  defmodule OneCallerUnguarded do
    @moduledoc false
    def entry(t) do
      root(t)
    rescue
      ArgumentError -> 0
    end

    def other(t), do: root(t) + 1

    defp root(t), do: :ets.update_counter(t, :k, 1)
  end

  defmodule ClosureInTry do
    @moduledoc false
    def root(tables) do
      Enum.each(tables, fn t -> :ets.update_counter(t, :k, 1) end)
    rescue
      ArgumentError -> :ok
    end
  end

  defmodule ClosureOutsideTry do
    @moduledoc false
    def root(tables, payload) do
      Enum.each(tables, fn t -> :ets.update_counter(t, :k, 1) end)

      try do
        :erlang.binary_to_term(payload)
      rescue
        _ -> :bad
      end
    end
  end

  defmodule ErpcCaught do
    @moduledoc false
    def root(node) do
      :erpc.call(node, Node, :self, [])
    catch
      :error, {:erpc, _} -> nil
    end
  end

  defmodule ErpcCaughtAsExit do
    @moduledoc false
    def root(node) do
      :erpc.call(node, Node, :self, [])
    catch
      :exit, _ -> nil
    end
  end
end
