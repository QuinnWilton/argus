defmodule Argus.Examples.WallClock do
  def now, do: :erlang.system_time()
end

defmodule Argus.Examples.MonotonicClock do
  def now, do: :erlang.monotonic_time()
end
