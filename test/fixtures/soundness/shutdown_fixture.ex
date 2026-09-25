defmodule Argus.Test.Soundness.Shutdown do
  @moduledoc """
  Real shutdown bugs a suppression once silenced, and the adversarial
  shapes beside each: `test/soundness/shutdown_test.exs` asserts the
  finding each must keep.
  """

  # ── A trapped exit nothing takes (review 2, item 9) ──────────────────
  # 98cfdb25 asked "no :EXIT handler" only of a listed GenServer: a
  # hand-rolled loop's own receive, and a server under an unlisted
  # wrapper, went unasked.

  defmodule Protocol do
    @moduledoc "A behaviour argus does not know, standing for ranch_protocol."
    @callback start_link(term(), term(), term()) :: {:ok, pid()}
  end

  defmodule TrapLoopFn do
    @moduledoc """
    A hand-rolled process: start_link spawns a closure that runs the
    loop. It traps exits, and its receive has no {:EXIT, _, _} clause:
    the linked parent's exit signal becomes a message nothing takes, so
    the process outlives its parent and the exit messages pile up.
    """
    def start_link(opts), do: {:ok, spawn_link(fn -> run(opts) end)}

    def put(pid, k, v), do: send(pid, {:put, k, v})

    def run(_opts) do
      Process.flag(:trap_exit, true)
      loop(%{})
    end

    defp loop(state) do
      receive do
        {:put, k, v} ->
          loop(Map.put(state, k, v))

        {:get, from, k} ->
          send(from, {:value, Map.get(state, k)})
          loop(state)
      end
    end
  end

  defmodule SetupThenLoop do
    @moduledoc """
    The trap in a setup helper, the loop the spawned fun runs after it:
    the process's receives are the fun's, not the helper's.
    """
    def start_link(opts) do
      {:ok,
       spawn_link(fn ->
         setup(opts)
         loop(%{})
       end)}
    end

    defp setup(_opts), do: Process.flag(:trap_exit, true)

    defp loop(state) do
      receive do
        {:put, k, v} -> loop(Map.put(state, k, v))
        :stop -> :ok
      end
    end
  end

  defmodule ProcLibLoop do
    @moduledoc """
    A proc_lib process under a behaviour argus does not know: its init
    traps, and its loop takes socket messages and no exit. What a spawn
    runs traps for its own process, which module_traps leaves out.
    """
    @behaviour Argus.Test.Soundness.Shutdown.Protocol

    @impl true
    def start_link(ref, transport, opts),
      do: {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}

    def init({_ref, _transport, opts}) do
      Process.flag(:trap_exit, true)
      loop(opts)
    end

    defp loop(opts) do
      receive do
        {:tcp, _sock, data} -> loop(Map.put(opts, :last, data))
        {:tcp_closed, _sock} -> :ok
      end
    end
  end

  defmodule ExitClauseLoop do
    @moduledoc "Quiet: the loop takes {:EXIT, ...}."
    def start_link, do: {:ok, spawn_link(fn -> run() end)}

    def run do
      Process.flag(:trap_exit, true)
      loop()
    end

    defp loop do
      receive do
        {:EXIT, _from, reason} ->
          exit(reason)

        {:work, from} ->
          send(from, :done)
          loop()
      end
    end
  end

  defmodule CatchAllLoop do
    @moduledoc "Quiet: the loop takes any message."
    def start_link, do: {:ok, spawn_link(fn -> run() end)}

    def run do
      Process.flag(:trap_exit, true)
      loop()
    end

    defp loop do
      receive do
        {:work, from} ->
          send(from, :done)
          loop()

        _other ->
          loop()
      end
    end
  end
end
