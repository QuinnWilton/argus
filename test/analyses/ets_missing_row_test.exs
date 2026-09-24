defmodule Argus.Analyses.EtsMissingRowTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Fixtures.MissingRow, as: Fixture

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp missing(modules) do
    {:ok, results} = Argus.analyze(modules, :races)

    for [_mod, func, kind, table, check, act, remover] <- results["ets_missing_row"],
        uniq: true,
        do: {short(func), kind, table, short(check), short(act), short(remover)}
  end

  describe "ets_missing_row" do
    test "a count after a lookup, while a timer's flush takes the row (sequin's shape)" do
      skip_without_souffle()

      assert [{"log/1", "named", ":debounce_buckets", "log/1", "log/1", "flush/2"}] =
               missing([Fixture.Debounce, Fixture.Debounce.Config])
    end

    test "counting with a default object stays quiet" do
      skip_without_souffle()
      assert missing([Fixture.WithDefault]) == []
    end

    test "a rescued miss stays quiet" do
      skip_without_souffle()
      assert missing([Fixture.Rescued]) == []
    end

    test "one process counting and flushing in its own callbacks stays quiet" do
      skip_without_souffle()
      assert missing([Fixture.OneOwner]) == []
    end
  end

  describe "ets_missing_row: where the miss is rescued" do
    test "a rescue around unrelated code after the act does not take its miss" do
      skip_without_souffle()

      assert [{"log/2", "named", ":unrelated_rescue_buckets", "log/2", "log/2", "flush/1"}] =
               missing([Fixture.UnrelatedRescue])
    end

    test "a helper that rescues its own act stays quiet" do
      skip_without_souffle()
      assert missing([Fixture.HelperRescue]) == []
    end

    test "a private function whose one caller rescues around the call stays quiet" do
      skip_without_souffle()
      assert missing([Fixture.CallerRescues]) == []
    end

    test "one caller that does not rescue keeps it reported" do
      skip_without_souffle()

      assert [{"do_log/1", "named", ":one_caller_rescue_buckets", _, _, "flush/1"}] =
               missing([Fixture.OneCallerRescues])
    end
  end

  describe "ets_missing_row across functions" do
    test "the act in a helper the found-row branch calls" do
      skip_without_souffle()

      assert [{"log/1", "named", ":helper_act_buckets", "log/1", "bump/1", "flush/1"}] =
               missing([Fixture.HelperAct])
    end

    test "the check in a helper that returns it" do
      skip_without_souffle()

      assert [{"log/1", "named", ":helper_check_buckets", "exists?/1", "log/1", "flush/1"}] =
               missing([Fixture.HelperCheck])
    end

    test "the act in another module" do
      skip_without_souffle()

      assert [{"log/1", "named", ":cross_module_buckets", "log/1", "bump/1", "flush/1"}] =
               missing([Fixture.CrossModuleAct, Fixture.Counter])
    end
  end

  describe "finding" do
    test "anchors the act and relates the check and the remover" do
      row = [
        "M",
        "M:log/1",
        "named",
        ":buckets",
        "M:log/1#49",
        "M:log/1#73",
        "M:flush/2#7"
      ]

      f = Races.finding(:ets_missing_row, row)
      assert f.severity == :warning
      assert f.mfa == {M, :log, 1}
      assert f.detail =~ ":buckets"
      assert f.detail =~ "M.flush/2"

      assert [%{label: "the read that decided the row was there"}, %{label: remover}] = f.related
      assert remover =~ "remove"
      assert Enum.any?(f.help, &(&1 =~ "update_counter/4"))
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
