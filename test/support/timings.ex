defmodule Argus.Test.Timings do
  @moduledoc """
  An ExUnit formatter that prints, when the suite ends, the slowest tests
  of the run as they ran: beside the others, at the run's `max_cases`.
  `mix test --slowest` measures a different run, since it sets `--trace`,
  which runs one test at a time with no timeout.

  On with `ARGUS_TEST_TIMINGS=N` (the N slowest; `test_helper.exs` adds
  it beside the CLI formatter), so CI's log shows which tests came near
  their timeout and how near.
  """

  use GenServer

  @impl true
  def init(_opts) do
    count =
      case Integer.parse(System.get_env("ARGUS_TEST_TIMINGS", "")) do
        {n, ""} when n > 0 -> n
        _ -> 20
      end

    {:ok, %{count: count, tests: []}}
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
        Enum.join(lines, "\n")
    )

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp format_ms(us), do: String.pad_leading("#{div(us, 1000)} ms", 10)

  defp format_timeout(:infinity), do: "no timeout"
  defp format_timeout(ms) when is_integer(ms), do: "#{div(ms, 1000)} s"
end
