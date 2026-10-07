defmodule Argus.Findings.Degradation do
  @moduledoc """
  What an analysis that did not run as planned is reported with: a
  `degraded` entry of `Argus.Findings` (`t:Argus.Findings.degradation/0`),
  the reason as it came and a sentence saying what it means for the
  findings. The same words whichever backend ran the analysis
  (`Argus.Findings.run/2`, `Argus.Run`).
  """

  @doc """
  The `degraded` entry for a finding builder that raised on some of an
  analysis's rows (`Argus.Findings.Build`'s failures): none when none did.
  """
  @spec rows(atom(), [Argus.Findings.Build.failure()]) :: [
          {:degraded, Argus.Findings.degradation()}
        ]
  def rows(_name, []), do: []

  def rows(name, [first | _] = failures) do
    [
      {:degraded,
       %{
         analysis: name,
         reason: {:finding_builder_crashed, first.exception},
         detail:
           "The #{name} analysis ran, but its finding builder crashed on " <>
             "#{length(failures)} row(s), first a #{first.relation} row: " <>
             "#{Exception.message(first.exception)}. Those rows are reported with " <>
             "their raw columns; every other finding is as usual. This is a bug in Argus."
       }}
    ]
  end

  @doc "The sentence a `degraded` entry explains `reason` with."
  @spec detail(atom(), term()) :: String.t()
  def detail(name, :flowlog_timeout) do
    "The #{name} analysis timed out in its engine and was skipped. " <>
      "Raise :timeout to include it."
  end

  def detail(name, {:flowlog_unavailable, reason}) do
    "The #{name} analysis did not run: " <> Argus.FlowLog.Toolchain.describe(reason)
  end

  def detail(name, {:points_to, :flowlog_timeout}) do
    "The #{name} analysis did not run: the process points-to it reads " <>
      "(priv/dl/points_to.dl) did not finish within :timeout. " <>
      "Raise :timeout to include it."
  end

  def detail(name, {:points_to, {:over_budget, over}}) do
    reached =
      Enum.map_join(over, ", ", fn {relation, rows, budget} ->
        "#{relation} reached #{rows} rows, over #{budget}"
      end)

    "The #{name} analysis did not run: the process points-to it reads " <>
      "(priv/dl/points_to.dl) outgrew its budget even bounded (#{reached})."
  end

  def detail(name, {:points_to, reason}) do
    "The #{name} analysis did not run: the process points-to it reads " <>
      "(priv/dl/points_to.dl) could not be derived: #{Argus.FlowLog.describe_error(reason)}."
  end

  def detail(name, reason) do
    "The #{name} analysis did not run: #{Argus.FlowLog.describe_error(reason)}."
  end
end
