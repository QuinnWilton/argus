defmodule Argus.FlowLog.Builder do
  @moduledoc """
  Builds engines for the whole VM, a batch at a time.

  One Cargo build compiles its programs side by side, and a VM runs one
  build at a time (`Argus.FlowLog.Toolchain.locked/2`): a build of one
  large program holds gigabytes. So the programs asked for while a build
  runs wait for it, and are then built together, whoever asked for
  them: forty callers each asking for one program make a few builds,
  not forty in turn.

  Each caller hears of its own programs only. A program that fails to
  compile fails the callers that asked for it, and no other.

  The builder is started on first use and runs each batch in a process
  of its own, so a batch that crashes fails its callers and leaves the
  builder taking the next.
  """

  use GenServer

  alias Argus.FlowLog.Program
  alias Argus.FlowLog.Toolchain

  @doc """
  Builds `programs` (`t:Argus.FlowLog.Program.build/0`) with `toolchain`
  in the next batch: `:ok` once each is installed, else the first of
  their failures. `opts` take `:progress` (`Argus.FlowLog.Program.engines/3`).
  """
  @spec build(Toolchain.t(), [Program.build()], keyword()) :: :ok | {:error, term()}
  def build(%Toolchain{} = toolchain, programs, opts) do
    GenServer.call(ensure_started(), {:build, toolchain, programs, opts}, :infinity)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init([]), do: {:ok, %{queue: [], running: nil}}

  @impl GenServer
  def handle_call({:build, toolchain, programs, opts}, from, state) do
    state = %{state | queue: [{from, toolchain, programs, opts} | state.queue]}
    {:noreply, maybe_start(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {ref, waiters}} = state) do
    results =
      case reason do
        {__MODULE__, :built, results} -> results
        other -> {:crashed, other}
      end

    Enum.each(waiters, fn {from, toolchain, programs, _opts} ->
      GenServer.reply(from, outcome(results, toolchain, programs))
    end)

    {:noreply, maybe_start(%{state | running: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_start(%{running: nil, queue: [_ | _] = queue} = state) do
    waiters = Enum.reverse(queue)

    # The batch's outcome is its exit reason: a process exiting so logs
    # nothing, and one that raises is told apart by any other reason.
    {_pid, ref} = spawn_monitor(fn -> exit({__MODULE__, :built, run(waiters)}) end)
    %{state | queue: [], running: {ref, waiters}}
  end

  defp maybe_start(state), do: state

  # Each toolchain's programs in one build (there is one toolchain in all
  # but a VM whose native sources changed under it).
  defp run(waiters) do
    waiters
    |> Enum.group_by(fn {_from, toolchain, _programs, _opts} -> toolchain.key end)
    |> Map.new(fn {key, [{_, toolchain, _, _} | _] = group} ->
      requests = Enum.map(group, fn {_from, _toolchain, programs, opts} -> {programs, opts} end)
      {key, Program.build(toolchain, requests)}
    end)
  end

  defp outcome({:crashed, reason}, _toolchain, _programs),
    do: {:error, {:build_crashed, reason}}

  defp outcome(results, toolchain, programs) do
    built = Map.fetch!(results, toolchain.key)

    Enum.find_value(programs, :ok, fn {_path, digest, profile} ->
      case Map.fetch(built, {digest, profile}) do
        {:ok, :ok} -> nil
        {:ok, {:error, _} = error} -> error
        :error -> {:error, {:build_crashed, {:not_built, digest}}}
      end
    end)
  end
end
