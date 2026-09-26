defmodule B.Loop do
  @moduledoc false

  @spec loop() :: :ok
  def loop do
    receive do
      :stop -> :ok
    end
  end
end
