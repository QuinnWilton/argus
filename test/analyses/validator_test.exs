defmodule Argus.Analyses.ValidatorTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.Validator.Roles
  alias Argus.Test.Memo

  defp reported do
    assert {:ok, r} = Memo.analyze([Roles], :unsafe_input)

    for f <- Argus.Findings.build(Argus.Analyses.UnsafeInput, r),
        f.title =~ "atom",
        uniq: true,
        do: elem(f.mfa, 1)
  end

  test "a value a raising validator accepted, directly or through a helper, is bounded" do
    refute :helper in reported()
    refute :wrapped in reported()
  end

  test "a list whose every element a validator accepted is bounded for a sink on each" do
    refute :each in reported()
  end

  test "a check that answers, one of another argument, or none leaves the sink reported" do
    assert Enum.sort(reported()) == [:answers, :other, :unchecked]
  end
end
