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

  # The second arm's label is reached only through the first arm's
  # get_map_elements fail edge, and the first arm ends in a jump: the
  # instruction laid out before the label is not its predecessor, and the
  # first arm's `:stale` in x1 is not what `x` holds in the second.
  def stale_arm(m, x) when is_map(m) do
    y =
      case m do
        %{a: a} ->
          Process.put(:k, :stale)
          {:first, a}

        %{b: b} ->
          GenServer.call(x, b)
      end

    Process.put(:y, y)
    Process.put(:z, y)
    Process.put(:w, {y, y})
    :ok
  end

  # The ref is in x0 until the receive's loop_rec writes the message over
  # it: nothing read it, so it is dropped.
  def monitor_then_receive(pid) do
    Process.monitor(pid)

    receive do
      msg -> msg
    end
  end

  # The pid this monitors came back from a supervisor start on one arm
  # and is the parameter on the other: not a started child on every path.
  def monitor_either(sup, spec, pid) do
    target =
      case spec do
        nil ->
          pid

        spec ->
          {:ok, started} = DynamicSupervisor.start_child(sup, spec)
          started
      end

    ref = Process.monitor(target)
    {:ok, ref}
  end

  # Both arms start the child: a started child on every path.
  def monitor_started(sup, spec) do
    {:ok, started} =
      case spec do
        nil -> DynamicSupervisor.start_child(sup, {Task, fn -> :ok end})
        spec -> DynamicSupervisor.start_child(sup, spec)
      end

    ref = Process.monitor(started)
    {:ok, ref}
  end

  # The destination is self() on one path and the parameter on the other.
  def timer_either(pid, ms) do
    dest = if pid == nil, do: self(), else: pid
    Process.send_after(dest, :tick, ms)
  end

  # self() in a register, moved about, then the timer's destination.
  def self_timer(ms) do
    me = self()
    Process.put(:me, me)
    Process.send_after(me, :tick, ms)
  end

  # Eight sixteen-armed cases in a row, each result kept in its own
  # register until the binary is built: every join sees what the arms
  # before it wrote arrive along all sixteen of its edges.
  def hex(<<a::4, b::4, c::4, d::4, e::4, f::4, g::4, h::4>>) do
    <<digit(a), digit(b), digit(c), digit(d), digit(e), digit(f), digit(g), digit(h)>>
  end

  @compile {:inline, digit: 1}
  defp digit(0), do: ?0
  defp digit(1), do: ?1
  defp digit(2), do: ?2
  defp digit(3), do: ?3
  defp digit(4), do: ?4
  defp digit(5), do: ?5
  defp digit(6), do: ?6
  defp digit(7), do: ?7
  defp digit(8), do: ?8
  defp digit(9), do: ?9
  defp digit(10), do: ?a
  defp digit(11), do: ?b
  defp digit(12), do: ?c
  defp digit(13), do: ?d
  defp digit(14), do: ?e
  defp digit(15), do: ?f
end
