defmodule Argus.Analyses.BuildCallbackTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.BuildCallback, as: B
  alias Argus.Test.Memo

  defp atom_sinks(modules) do
    assert {:ok, r} = Memo.analyze(modules, :unsafe_input)

    for f <- Argus.Findings.build(Argus.Analyses.UnsafeInput, r),
        f.title =~ "atom",
        uniq: true,
        do: f.mfa
  end

  test "a template engine's compile-time callbacks are no way in; its runtime helper is" do
    assert atom_sinks([B.Engine]) == [{B.Engine, :render_attr, 1}]
  end

  test "a code sink only a template engine's callbacks reach is reported from no export" do
    assert {:ok, r} = Memo.analyze([B.Engine], :unsafe_input)

    refute Enum.any?(
             Argus.Findings.build(Argus.Analyses.UnsafeInput, r),
             &(&1.title =~ "code execution")
           )
  end

  test "a Mix SCM's callbacks, handed a dependency's metadata, are no way in" do
    assert atom_sinks([B.SCM]) == []
  end

  test "a hidden helper of a build behaviour's module, which its callback calls, is no way in" do
    assert atom_sinks([B.HiddenSCM]) == []
  end
end
