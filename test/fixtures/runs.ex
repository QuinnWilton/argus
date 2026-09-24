defmodule Argus.Test.Runs do
  @moduledoc """
  How many cases a slow property checks: `quick` in an ordinary run, the
  `full` count under `ARGUS_PROPERTIES=full` — the run before a release,
  and after changing what the property covers. A property whose cases
  each compile modules or extract beams sets the suite's wall time on
  its own at the full count.
  """

  @doc "`quick`, or `full` under `ARGUS_PROPERTIES=full`."
  @spec max_runs(pos_integer(), pos_integer()) :: pos_integer()
  def max_runs(quick, full) when quick <= full do
    if System.get_env("ARGUS_PROPERTIES") == "full", do: full, else: quick
  end
end
