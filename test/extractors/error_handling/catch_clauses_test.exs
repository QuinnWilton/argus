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

  describe "a tuple's tag, apart from the reason itself" do
    test "an is_tagged_tuple on the reason is a tuple tag" do
      summary =
        handler([
          {:test, :is_tagged_tuple, {:f, 6}, [{:x, 1}, 2, {:atom, :noproc}]},
          :return,
          {:label, 6},
          {:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}
        ])

      assert summary.tags == [{:*, :noproc}]
      assert summary.tuple_tags == [{:*, :noproc}]
    end

    test "comparing the reason itself with an atom is not" do
      summary =
        handler([
          {:test, :is_eq_exact, {:f, 6}, [{:x, 1}, {:atom, :noproc}]},
          :return,
          {:label, 6},
          {:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}
        ])

      assert summary.tags == [{:*, :noproc}]
      assert summary.tuple_tags == []
    end

    test "a comparison on a tuple's first element, through a copy, is a tuple tag" do
      summary =
        handler([
          {:test, :is_tuple, {:f, 6}, [{:x, 1}]},
          {:get_tuple_element, {:x, 1}, 0, {:x, 3}},
          {:move, {:x, 3}, {:x, 4}},
          {:select_val, {:x, 4}, {:f, 6}, {:list, [{:atom, :noproc}, {:f, 7}]}},
          {:label, 7},
          :return,
          {:label, 6},
          {:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}
        ])

      assert summary.tuple_tags == [{:*, :noproc}]
    end

    test "a register overwritten after holding the first element is no longer one" do
      summary =
        handler([
          {:get_tuple_element, {:x, 1}, 0, {:x, 3}},
          {:get_tuple_element, {:x, 1}, 1, {:x, 3}},
          {:test, :is_eq_exact, {:f, 6}, [{:x, 3}, {:atom, :noproc}]},
          :return,
          {:label, 6},
          {:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}
        ])

      assert summary.tags == [{:*, :noproc}]
      assert summary.tuple_tags == []
    end
  end
end
