defmodule Argus.Test.Soundness do
  @moduledoc """
  The findings a program's real bug must keep.

  A suppression quiets a shape its negative fixture pins; the review of
  a precision round asks what else the same syntax covers, and each
  real bug it found silenced, with the adversarial variants written
  beside it (the nearest shapes on another path, caller, source, branch
  or clause), becomes a positive fixture here: the finding it must
  produce, at the severity the rule gave it before the suppression.
  `test/soundness/<concern>_test.exs` lists them, one test each.
  """

  alias Argus.Test.Memo

  @typedoc "What a test expects: the severity, the title and the anchor's `{module, function, arity}`."
  @type expected :: {Argus.Findings.severity(), String.t(), mfa()}

  @doc """
  The findings `analysis` reports over `modules`, solved alone as one
  program, as `{severity, title, mfa}`, sorted.
  """
  @spec fired([module()], atom()) :: [expected()]
  def fired(modules, analysis) when is_list(modules) and is_atom(analysis) do
    {:ok, result} = Memo.run_analyses(modules, analyses: [analysis])

    result.findings
    |> Enum.filter(&(&1.analysis == analysis))
    |> Enum.map(&{&1.severity, &1.title, &1.mfa})
    |> Enum.sort()
  end
end
