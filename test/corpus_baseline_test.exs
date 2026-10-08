defmodule Argus.CorpusBaselineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Corpus.Baseline

  @moduletag :tmp_dir

  defp finding(fields) do
    Map.merge(
      %{analysis: :ets, title: "A title", severity: :warning, module: Foo, mfa: {Foo, :f, 1}},
      Map.new(fields)
    )
  end

  defp checkout(tmp), do: %{name: "repo-abc1234", dir: Path.join(tmp, "repo-abc1234")}

  describe "entries/2" do
    test "names a finding by its function and its line in the checkout", %{tmp_dir: tmp} do
      co = checkout(tmp)
      file = Path.join(co.dir, "lib/foo.ex")

      assert Baseline.entries(co, %{findings: [finding(file: file, line: 12)]}) ==
               [{:ets, "A title", :warning, "Foo.f/1", "lib/foo.ex:12"}]
    end

    test "names a finding without a function by its module, and one without a file by none",
         %{tmp_dir: tmp} do
      assert Baseline.entries(checkout(tmp), %{findings: [finding(mfa: nil)]}) ==
               [{:ets, "A title", :warning, "Foo", nil}]
    end

    test "does not depend on the order the findings came in", %{tmp_dir: tmp} do
      a = finding(title: "A")
      b = finding(title: "B")

      assert Baseline.entries(checkout(tmp), %{findings: [a, b]}) ==
               Baseline.entries(checkout(tmp), %{findings: [b, a]})
    end
  end

  describe "changes/2" do
    test "counts a finding reported once more as one added" do
      one = {:ets, "A", :warning, "Foo.f/1", nil}

      assert Baseline.changes([one], [one, one]) == %{added: [one], removed: []}
      assert Baseline.changes([one, one], [one]) == %{added: [], removed: [one]}
    end

    test "sees a finding whose severity moved as one removed and one added" do
      was = {:ets, "A", :warning, "Foo.f/1", nil}
      now = put_elem(was, 2, :error)

      assert Baseline.changes([was], [now]) == %{added: [now], removed: [was]}
    end

    property "the baseline, less what was removed, with what was added, is what is now" do
      entry =
        StreamData.tuple(
          {StreamData.member_of([:ets, :races]), StreamData.member_of(["A", "B"]),
           StreamData.member_of([:warning, :error]), StreamData.member_of(["F.f/1", nil]),
           StreamData.member_of(["lib/a.ex:1", nil])}
        )

      check all(
              baseline <- StreamData.list_of(entry),
              current <- StreamData.list_of(entry)
            ) do
        %{added: added, removed: removed} = Baseline.changes(baseline, current)

        assert Enum.sort((baseline -- removed) ++ added) == Enum.sort(current)
        assert added -- current == []
        assert removed -- baseline == []
      end
    end
  end

  describe "compare/2" do
    test "records the first run's entries, and compares every later run with them",
         %{tmp_dir: tmp} do
      co = checkout(tmp)
      first = [{:ets, "A", :warning, "Foo.f/1", nil}]
      second = [{:ets, "B", :warning, "Foo.f/1", nil}]

      assert Baseline.compare(co, first) == {:recorded, 1}
      assert Baseline.compare(co, second) == %{added: second, removed: first}
      # Comparing never moves the baseline: the second run's changes are
      # still the third's.
      assert Baseline.compare(co, second) == %{added: second, removed: first}

      :ok = Baseline.write!(co, second)
      assert Baseline.compare(co, second) == %{added: [], removed: []}
    end

    test "takes a baseline that does not decode as none, and records afresh", %{tmp_dir: tmp} do
      co = checkout(tmp)
      File.mkdir_p!(Path.dirname(Baseline.path(co)))
      File.write!(Baseline.path(co), "not a term")

      assert Baseline.read(co) == :none
      assert Baseline.compare(co, []) == {:recorded, 0}
      assert Baseline.read(co) == {:ok, []}
    end
  end

  describe "report/2" do
    test "puts the title that moved most first, with each checkout's rows under it",
         %{tmp_dir: tmp} do
      co = checkout(tmp)
      a = {:ets, "A", :warning, "Foo.f/1", "lib/foo.ex:3"}
      b1 = {:races, "B", :error, "Foo.g/0", nil}
      b2 = {:races, "B", :error, "Foo.h/0", nil}

      assert Baseline.report([{co, %{added: [b1, b2], removed: [a]}}], rows: true) == [
               "+2 -0      races: B",
               "    + repo-abc1234  Foo.g/0 (error)",
               "    + repo-abc1234  Foo.h/0 (error)",
               "+0 -1      ets: A",
               "    - repo-abc1234  Foo.f/1 lib/foo.ex:3 (warning)"
             ]

      assert Baseline.report([{co, %{added: [b1, b2], removed: [a]}}]) ==
               ["+2 -0      races: B", "+0 -1      ets: A"]
    end

    test "is empty when nothing moved", %{tmp_dir: tmp} do
      assert Baseline.report([{checkout(tmp), %{added: [], removed: []}}]) == []
    end
  end
end
