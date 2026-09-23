defmodule Argus.Test.Fixtures.Instr do
  @moduledoc false
  # Shapes whose registers are written by instructions that do not name
  # them as a destination, or reached along edges a linear walk misses.
  # Pinned by the Instr, Dataflow and Helpers tests.

  # The rescued reason arrives in x1 at the handler's try_case, and the
  # class in x0: neither is the function's parameter.
  def handler(a, b) do
    :ets.lookup(a, b)
  rescue
    e -> :ets.insert(:tbl, {e})
  end

  # `fallback` lives into the handler in a y register written before the
  # try; the handler reaches it only along the exception edge.
  def fallback(tab, key) do
    v =
      case key do
        1 -> :one
        _ -> :other
      end

    try do
      :ets.lookup(tab, key)
    catch
      :exit, reason -> {v, reason}
    end
  end

  # The received message is loop_rec's write, not the parameter.
  def recv(_state) do
    receive do
      pid -> GenServer.call(pid, :x)
    end
  end

  # get_list writes the tail into x0, over the parameter.
  def tailp([h | t]), do: GenServer.call(t, h)
end
