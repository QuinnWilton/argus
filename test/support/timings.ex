defmodule Argus.Test.Timings do
  @moduledoc """
  An ExUnit formatter that prints, when the suite ends, the slowest tests
  of the run as they ran: beside the others, at the run's `max_cases`.
  `mix test --slowest` measures a different run, since it sets `--trace`,
  which runs one test at a time with no timeout.

  On with `ARGUS_TEST_TIMINGS=N` (the N slowest; `test_helper.exs` adds
  it beside the CLI formatter), so CI's log shows which tests came near
  their timeout and how near.

  It also counts what the suite's FlowLog engines did in this VM (a
  peer's are its own): how many started and commits they answered, and
  the time each took in all (`Argus.FlowLog.Engine`'s telemetry).
  """

  use GenServer

  @impl true
  def init(_opts) do
    count =
      case Integer.parse(System.get_env("ARGUS_TEST_TIMINGS", "")) do
        {n, ""} when n > 0 -> n
        _ -> 20
      end

    # Slots: starts, start time, commits, commit time (native units).
    engines = :counters.new(4, [:write_concurrency])

    :telemetry.attach_many(
      {__MODULE__, self()},
      [[:argus, :flowlog, :engine, :start], [:argus, :flowlog, :engine, :commit]],
      &__MODULE__.count_engine/4,
      engines
    )

    {:ok, %{count: count, tests: [], engines: engines}}
  end

  @doc false
  def count_engine([:argus, :flowlog, :engine, event], %{duration: duration}, _meta, engines) do
    slot = if event == :start, do: 1, else: 3
    :counters.add(engines, slot, 1)
    :counters.add(engines, slot + 1, duration)
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    timeout = Map.get(test.tags, :timeout, ExUnit.configuration()[:timeout])
    entry = {test.time, test.module, test.name, timeout}
    {:noreply, %{state | tests: [entry | state.tests]}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    slowest = state.tests |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.take(state.count)

    lines =
      for {us, module, name, timeout} <- slowest do
        "  #{format_ms(us)} of #{format_timeout(timeout)}  #{inspect(module)} #{name}"
      end

    IO.puts(
      "\nThe #{length(slowest)} slowest tests, as they ran beside the others:\n" <>
        Enum.join(lines, "\n") <> "\n\n" <> engines(state.engines)
    )

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp engines(counters) do
    [starts, start_time, commits, commit_time] = Enum.map(1..4, &:counters.get(counters, &1))
    seconds = &Float.round(System.convert_time_unit(&1, :native, :millisecond) / 1000, 1)

    "FlowLog engines: #{starts} started (#{seconds.(start_time)} s in all), " <>
      "#{commits} commits (#{seconds.(commit_time)} s in all)"
  end

  defp format_ms(us), do: String.pad_leading("#{div(us, 1000)} ms", 10)

  defp format_timeout(:infinity), do: "no timeout"
  defp format_timeout(ms) when is_integer(ms), do: "#{div(ms, 1000)} s"
end
