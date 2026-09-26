defmodule A.Same do
  @moduledoc false

  # Sends a message its own spawned loop never takes: found per-app.
  @spec start() :: {:job, 1}
  def start do
    pid = spawn(__MODULE__, :loop, [])
    send(pid, {:job, 1})
  end

  @spec loop() :: :ok
  def loop do
    receive do
      :stop -> :ok
    end
  end
end

defmodule A.Cross do
  @moduledoc false

  # The same flaw across the app boundary: B.Loop lives in a sibling app,
  # whose beams a per-app run does not analyze.
  @spec start() :: {:job, 1}
  def start do
    pid = spawn(B.Loop, :loop, [])
    send(pid, {:job, 1})
  end
end
