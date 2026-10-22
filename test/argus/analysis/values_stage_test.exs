defmodule Argus.Analysis.ValuesStageTest do
  @moduledoc """
  The values stage (`priv/dl/values.dl`): which literals each of the
  program's parameters may hold, through any chain of callers passing
  them on, where each was spelled, and which of those sets are complete,
  over the fixtures in `test/fixtures/values_fixture.ex`.
  """
  # Not async: the budget test solves a copy of the rules as argus's own
  # would be solved, and captures the warning it logs.
  use ExUnit.Case, async: false
  @moduletag :flowlog
  @moduletag :tmp_dir
  @moduletag timeout: 1_800_000

  import ExUnit.CaptureLog

  alias Argus.{Analysis, Pipeline}
  alias Argus.Test.Fixtures.Values

  @modules [
    Values.Chain,
    Values.Exported,
    Values.Computed,
    Values.Defaulted,
    Values.Captured,
    Values.Fifth,
    Values.Results,
    Values.Started
  ]

  defp facts!(tmp) do
    dir = Path.join(tmp, "facts")
    {:ok, _} = Pipeline.run(@modules, dir, extractors: [Argus.Extractors.TermFlow])
    :ok = Analysis.derive_stage0(dir)
    dir
  end

  defp rows(dir, relation),
    do:
      dir |> Path.join(relation <> ".facts") |> File.read!() |> Argus.Tsv.decode() |> Enum.sort()

  defp func(mod, name, arity), do: Argus.InstrId.func_id(mod, name, arity)

  defp values(dir, mod, name, arity, pos) do
    f = func(mod, name, arity)
    for [^f, ^pos, value] <- rows(dir, "param_value"), do: value
  end

  defp complete?(dir, mod, name, arity, pos),
    do: [func(mod, name, arity), pos] in rows(dir, "param_complete")

  describe "the full stage" do
    setup %{tmp_dir: tmp} do
      dir = facts!(tmp)
      assert :ok = Analysis.derive_values(dir)
      %{dir: dir}
    end

    test "a literal reaches a parameter through every wrapper, from every caller", %{dir: dir} do
      assert values(dir, Values.Chain, :wrap, 1, "0") == [":alpha", ":beta"]
      assert values(dir, Values.Chain, :deepest, 2, "0") == [":alpha", ":beta"]
      assert values(dir, Values.Chain, :deepest, 2, "1") == ["1"]
      assert complete?(dir, Values.Chain, :deepest, 2, "0")
      assert rows(dir, "values_mode") == [["full"]]
    end

    test "what a caller hands is its own, not every caller's", %{dir: dir} do
      run_a = func(Values.Chain, :run_a, 0)
      wrap = func(Values.Chain, :wrap, 1)

      assert [[^run_a, ^wrap, "0", ":alpha"]] =
               for([^run_a | _] = row <- rows(dir, "arg_value"), do: row)

      assert [run_a, wrap, "0"] in rows(dir, "arg_complete")

      # A wrapper hands on what its own parameter holds.
      inner = func(Values.Chain, :inner, 2)
      handed = for [^wrap, ^inner, "0", value] <- rows(dir, "arg_value"), do: value
      assert handed == [":alpha", ":beta"]
    end

    test "a literal's origin is the call spelling it, through every wrapper", %{dir: dir} do
      deepest = func(Values.Chain, :deepest, 2)
      run_a = func(Values.Chain, :run_a, 0)
      run_b = func(Values.Chain, :run_b, 0)

      origins =
        for [^deepest, "0", caller, site, value] <- rows(dir, "param_origin"),
            do: {caller, String.starts_with?(site, caller <> "#"), value}

      assert Enum.sort(origins) == [{run_a, true, ":alpha"}, {run_b, true, ":beta"}]

      # The key is spelled by the wrapper, not by either caller.
      wrap = func(Values.Chain, :wrap, 1)

      assert [[^deepest, "1", ^wrap, _, "1"]] =
               for([^deepest, "1" | _] = r <- rows(dir, "param_origin"), do: r)
    end

    test "a helper's result holds what it returns, at each call", %{dir: dir} do
      assert values(dir, Values.Results, :take, 1, "0") == [":eta", ":zeta"]
      refute complete?(dir, Values.Results, :take, 1, "0")
    end

    test "a start hands its argument to init/1, which is anyone's", %{dir: dir} do
      assert values(dir, Values.Started, :init, 1, "0") == [":theta"]
      refute complete?(dir, Values.Started, :init, 1, "0")
    end

    test "an export's parameter, and what it hands on, is never complete", %{dir: dir} do
      assert values(dir, Values.Exported, :hidden, 1, "0") == [":gamma"]
      refute complete?(dir, Values.Exported, :lookup, 1, "0")
      refute complete?(dir, Values.Exported, :hidden, 1, "0")
    end

    test "a computed argument leaves the literals beside it incomplete", %{dir: dir} do
      assert values(dir, Values.Computed, :take, 1, "0") == [":delta"]
      refute complete?(dir, Values.Computed, :take, 1, "0")
    end

    test "a value term-flow does not follow beside a literal leaves the set incomplete",
         %{dir: dir} do
      assert values(dir, Values.Defaulted, :take, 1, "0") == [":iota"]
      refute complete?(dir, Values.Defaulted, :take, 1, "0")
      # nil is no value a rule names, and not all the parameter can hold.
      assert values(dir, Values.Defaulted, :mark, 1, "0") == [":ok"]
      refute complete?(dir, Values.Defaulted, :mark, 1, "0")
    end

    test "a function captured as a fun has callers the program does not show", %{dir: dir} do
      assert values(dir, Values.Captured, :read, 1, "0") == [":epsilon"]
      refute complete?(dir, Values.Captured, :read, 1, "0")
    end

    test "every argument is followed, the fifth too", %{dir: dir} do
      assert values(dir, Values.Fifth, :five, 5, "4") == [":e"]
      assert complete?(dir, Values.Fifth, :five, 5, "4")
    end

    test "a library function has no parameters here", %{dir: dir} do
      refute Enum.any?(rows(dir, "param_value"), fn [f | _] -> String.starts_with?(f, ":ets:") end)
    end
  end

  test "a program past the budget knows no value, and says so", %{tmp_dir: tmp} do
    dir = facts!(tmp)
    root = Path.join(tmp, "dl")
    File.cp_r!(Argus.Dl.root(), root)
    path = Path.join(root, "values.dl")
    File.write!(path, String.replace(File.read!(path), "500000", "2"))

    opts = [
      rules_path: path,
      unknown_rules_path: Path.join(root, "values_unknown.dl")
    ]

    log = capture_log(fn -> assert :ok = Analysis.derive_values(dir, opts) end)

    assert log =~ "values: the stage outgrew its budget"
    assert rows(dir, "values_mode") == [["unknown"]]
    assert rows(dir, "param_value") == []
    assert rows(dir, "param_complete") == []
    assert rows(dir, "arg_value") == []
  end
end
