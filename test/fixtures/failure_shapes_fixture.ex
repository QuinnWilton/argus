defmodule Argus.Test.Fixtures.FailureLogReport do
  @moduledoc """
  Catch-alls around one Elixir `Logger` call and nothing else: a
  module's own failure reporter, whose handler keeps a broken log
  handler from crashing the code that reports. What a failure there
  loses is the log line.
  """

  require Logger

  # pdf_elixide's `Logging.report_failure/3`.
  def report(kind, reason, stacktrace) do
    Logger.error(
      "could not forward the captured records: " <> Exception.format_banner(kind, reason),
      forwarder: true,
      crash_reason: {reason, stacktrace}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def note(reason) do
    try do
      Logger.warning("giving up: " <> inspect(reason))
    catch
      _, _ -> :ok
    end
  end
end

defmodule Argus.Test.Fixtures.FailureLogWork do
  @moduledoc """
  The twins of FailureLogReport whose try holds the program's own work
  beside the `Logger` call: a catch-all there swallows its bug.
  """

  require Logger

  def apply_and_log(state) do
    try do
      apply_entry(state)
      Logger.info("applied")
    catch
      _, _ -> :ok
    end
  end

  # The work runs inside the log line's arguments.
  def log_applied(state) do
    try do
      Logger.info("applied: " <> Integer.to_string(apply_entry(state)))
    catch
      _, _ -> :ok
    end
  end

  def apply_entry(state), do: Map.fetch!(state, :entry) + 1
end

defmodule Argus.Test.Fixtures.FailureWhereisReturned do
  @moduledoc """
  Lookups returned to their callers, judged at the callers' uses
  (zwave's `EventBus`), and ones compared with a value that is never
  nil (ex_ast's `real_stdout?/0`).
  """

  # A cast to nil drops the message, as a cast to a dead server does.
  defp pid, do: Process.whereis(:failure_event_bus)

  def publish(event), do: GenServer.cast(pid(), {:event, event})

  def subscribe(listener), do: GenServer.cast(pid(), {:subscribe, listener})

  # Every caller tests the result against nil.
  defp server, do: Process.whereis(:failure_server)

  def ping do
    case server() do
      nil -> :down
      pid -> send(pid, :ping)
    end
  end

  # A wrapper that tail-returns its private callee's lookup, to a caller
  # that casts.
  defp bus, do: pid()

  def touch, do: GenServer.cast(bus(), :touch)

  # The caller's group leader is a pid: the comparison decides, and
  # nil reaches no use.
  def real_stdout?, do: Process.group_leader() == Process.whereis(:user)

  def owner?, do: self() == Process.whereis(:failure_owner)
end

defmodule Argus.Test.Fixtures.FailureWhereisReturnedUsed do
  @moduledoc """
  The twins of FailureWhereisReturned whose nil reaches a use that
  fails on it.
  """

  defp metrics, do: Process.whereis(:failure_metrics)

  # A send to nil raises badarg.
  def bump, do: send(metrics(), :bump)

  # One caller casts, the other sends: the send still fails.
  defp sink, do: Process.whereis(:failure_sink)

  def drop(msg), do: GenServer.cast(sink(), msg)

  def push(msg), do: send(sink(), msg)

  # Two lookups compared: both may be nil, and nil == nil.
  def same?, do: Process.whereis(:failure_a) == Process.whereis(:failure_b)
end

defmodule Argus.Test.Fixtures.FailureRaisingElse do
  @moduledoc """
  A file opened in a `with` whose every failure goes to an `else` that
  raises (ex_mp4's `DataWriter.File.write/4`), or to a helper of the
  module that always raises: no path returns with it open.
  """

  def copy_into(path, data) do
    with {:ok, fd} <- File.open(path, [:write]),
         :ok <- check(data),
         :ok <- IO.binwrite(fd, data),
         :ok <- File.close(fd) do
      :ok
    else
      error -> raise "cannot write: #{inspect(error)}"
    end
  end

  def write_checked(path, data) do
    {:ok, fd} = File.open(path, [:write])

    case :file.write_file(path <> ".bak", data) do
      :ok ->
        IO.binwrite(fd, data)
        File.close(fd)

      error ->
        fail!(error)
    end
  end

  defp fail!(reason), do: raise(ArgumentError, "cannot write: #{inspect(reason)}")

  defp check(data), do: if(data == "", do: {:error, :empty}, else: :ok)
end

defmodule Argus.Test.Fixtures.FailureReturningElse do
  @moduledoc """
  The twins of FailureRaisingElse whose `else`, or helper, returns: the
  file stays open on that path.
  """

  def copy_into(path, data) do
    with {:ok, fd} <- File.open(path, [:write]),
         :ok <- check(data),
         :ok <- IO.binwrite(fd, data),
         :ok <- File.close(fd) do
      :ok
    else
      error -> {:error, {:cannot_write, error}}
    end
  end

  def write_checked(path, data) do
    {:ok, fd} = File.open(path, [:write])

    case :file.write_file(path <> ".bak", data) do
      :ok ->
        IO.binwrite(fd, data)
        File.close(fd)

      error ->
        fail(error)
    end
  end

  # Raises for one reason, returns for the others.
  defp fail({:error, :enospc}), do: raise(ArgumentError, "disk full")
  defp fail(reason), do: {:error, reason}

  defp check(data), do: if(data == "", do: {:error, :empty}, else: :ok)
end
