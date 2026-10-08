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
