defmodule Argus.Test.Fixtures.MailboxRetryChain do
  @moduledoc """
  attesto_phoenix's signal sweeper: `:dispatch` is armed only when a
  worker fails to start, two branches down from the clause for it (a
  `case` on the start, then an `if` on the failure count), so the
  clause is a bounded retry, not a periodic loop, and the casts that
  dispatch arm no second chain of one.
  """

  use GenServer

  def init(_), do: {:ok, %{queue: [], active: nil, retry_ref: nil, failures: 0}}

  def handle_cast({:enqueue, item}, state),
    do: {:noreply, maybe_dispatch(%{state | queue: state.queue ++ [item]})}

  def handle_info(:dispatch, state),
    do: {:noreply, state |> Map.put(:retry_ref, nil) |> maybe_dispatch()}

  defp maybe_dispatch(%{active: active} = state) when not is_nil(active), do: state
  defp maybe_dispatch(%{retry_ref: ref} = state) when is_reference(ref), do: state
  defp maybe_dispatch(%{queue: []} = state), do: state

  defp maybe_dispatch(%{queue: [item | rest]} = state) do
    case start_worker(item) do
      {:ok, pid} -> %{state | queue: rest, active: pid}
      {:error, _reason} -> retry_or_drop(%{state | queue: rest}, item)
    end
  end

  defp retry_or_drop(state, item) do
    if state.failures < 3 do
      schedule_dispatch(%{state | queue: [item | state.queue], failures: state.failures + 1})
    else
      %{state | failures: 0}
    end
  end

  defp schedule_dispatch(state),
    do: %{state | retry_ref: Process.send_after(self(), :dispatch, 1000)}

  defp start_worker(_item), do: Application.get_env(:probe, :worker, {:error, :down})
end

defmodule Argus.Test.Fixtures.MailboxPeriodicChain do
  @moduledoc """
  MailboxRetryChain's twin: the clause re-arms through two helpers
  that each call the next on every path, a periodic loop, and the kick
  arms it again over the ref the loop keeps.
  """

  use GenServer

  def init(_), do: {:ok, %{timer: nil}}

  def handle_cast(:kick, state), do: {:noreply, schedule_poll(state)}

  def handle_info(:poll, state), do: {:noreply, poll(state)}

  defp poll(state) do
    work()
    schedule_poll(state)
  end

  defp schedule_poll(state), do: %{state | timer: Process.send_after(self(), :poll, 1000)}

  defp work, do: Application.get_env(:probe, :work, :ok)
end

defmodule Argus.Test.Fixtures.MailboxOpenRequest do
  @moduledoc """
  tm_mercury's reader: the API calls the server with atoms it has no
  clause of their own for, and the last clauses take them by shape, an
  atom (`when is_atom(cmd)`) or a pair (`{op, arg} when is_atom(op)`),
  and run them as commands.
  """

  use GenServer

  def version(pid), do: GenServer.call(pid, :version)
  def temperature(pid), do: GenServer.call(pid, :get_temperature)
  def region(pid, region), do: GenServer.call(pid, {:set_region, region})
  def status(pid), do: GenServer.call(pid, :status)

  def init(_), do: {:ok, %{conn: nil, status: :idle}}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({op, arg}, _from, %{conn: conn} = state) when is_atom(op),
    do: {:reply, execute(conn, [op, arg]), state}

  def handle_call(cmd, _from, %{conn: conn} = state) when is_atom(cmd),
    do: {:reply, execute(conn, [cmd]), state}

  defp execute(_conn, cmd), do: Application.get_env(:probe, :reader, cmd)
end

defmodule Argus.Test.Fixtures.MailboxOpenRequestShape do
  @moduledoc """
  MailboxOpenRequest's twin: the open clauses take an atom and a pair,
  and the API sends a 3-tuple no clause takes, whose tag is an atom.
  """

  use GenServer

  def configure(pid, key, value), do: GenServer.call(pid, {:configure, key, value})

  def init(_), do: {:ok, %{conn: nil}}

  def handle_call({op, arg}, _from, %{conn: conn} = state) when is_atom(op),
    do: {:reply, execute(conn, [op, arg]), state}

  def handle_call(cmd, _from, %{conn: conn} = state) when is_atom(cmd),
    do: {:reply, execute(conn, [cmd]), state}

  defp execute(_conn, cmd), do: Application.get_env(:probe, :reader, cmd)
end
