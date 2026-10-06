defmodule Argus.Examples.ClockCalls do
  @moduledoc "An informational extension: calls that read wall-clock time."
  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Facts
  alias Argus.InstrId

  @impl true
  def relations, do: [:clock_read]

  @impl true
  def extract(data) do
    facts =
      Helpers.each_remote_call(data, %{}, fn facts, ctx, mfa ->
        if mfa == {:erlang, :system_time, 0},
          do:
            Facts.add_fact(facts, :clock_read, [InstrId.mint(ctx.func_id, ctx.idx), ctx.func_id]),
          else: facts
      end)

    Map.new(facts, fn {name, rows} -> {name, Enum.sort(rows)} end)
  end
end

defmodule Argus.Examples.ClockUses do
  @moduledoc "Turns the tutorial's clock_use rows into informational findings."
  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :tutorial_clock
  @impl true
  def description, do: "functions that read wall-clock time"
  @impl true
  def rules_file, do: "clock.dl"
  @impl true
  def extractors, do: [Argus.Examples.ClockCalls]

  @impl true
  def output_relations do
    [
      %{
        name: :clock_use,
        fields: [{:site, :instr_id, "the clock call"}, {:func, :func_id, "the caller"}],
        key: [:site],
        doc: "A call reading wall-clock time; this is not a defect claim."
      }
    ]
  end

  @impl true
  def finding(:clock_use, [site, func]) do
    Findings.new(:info, "Reads wall-clock time", "#{func} reads the system clock.",
      at: Findings.at_instr(site)
    )
  end
end
