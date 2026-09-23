defmodule Argus.Extractors.ErrorHandling.CatchClausesTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ErrorHandling.CatchClauses

  # A handler at label 5: try_case leaves class, reason and stacktrace in
  # x0-x2, then `body`.
  defp handler(body), do: CatchClauses.analyse([{:label, 5}, {:try_case, {:y, 0}}] ++ body, 5)

  describe "the reason's registers follow Argus.Instr" do
    test "a call destroys every x register, not only its arguments" do
      summary =
        handler([
          {:move, {:x, 1}, {:x, 3}},
          {:call_ext, 1, {:extfunc, :m, :log, 1}},
          {:test, :is_eq_exact, {:f, 6}, [{:x, 3}, {:atom, :noproc}]},
          :return,
          {:label, 6},
          :return
        ])

      # x3 no longer holds the reason: neither path has tested it.
      assert summary.totals == [:*]
    end

    test "an instruction that overwrites the reason's register ends the alias" do
      summary =
        handler([
          {:get_list, {:x, 2}, {:x, 1}, {:x, 4}},
          {:test, :is_eq_exact, {:f, 6}, [{:x, 1}, {:atom, :noproc}]},
          :return,
          {:label, 6},
          :return
        ])

      assert summary.totals == [:*]
    end

    test "a test on the reason, or a copy of it, is a tested catch" do
      summary =
        handler([
          {:swap, {:x, 1}, {:x, 5}},
          {:test, :is_eq_exact, {:f, 6}, [{:x, 5}, {:atom, :noproc}]},
          :return,
          {:label, 6},
          {:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}
        ])

      assert summary.totals == []
      assert summary.tags == [{:*, :noproc}]
    end
  end
end
