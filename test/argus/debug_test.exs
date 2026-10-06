defmodule Argus.DebugTest do
  use ExUnit.Case, async: true
  @moduletag :souffle
  @moduletag :tmp_dir

  alias Argus.Debug
  alias Argus.Test.Memo

  defmodule EmptyExtractor do
    @behaviour Argus.Extractor
    @impl true
    def relations, do: [:tutorial_site]
    @impl true
    def extract(_data), do: %{}
  end

  defp custom_bundle(tmp, source \\ nil, opts \\ []) do
    rules = Path.join(tmp, "custom.dl")

    File.write!(
      rules,
      source ||
        """
        .include #{JSON.encode!(Argus.Dl.path("base.dl"))}
        .decl selected(func: symbol)
        selected(f) :- function_def(f, _, "init", _, _).
        .output selected
        """
    )

    Debug.capture!(
      [Argus.Test.Fixtures.CleansUpEnteringLoop],
      {:custom, rules},
      Path.join(tmp, "bundle"),
      opts
    )
  end

  test "PR #8 inspection preserves graph outputs and exposes process-local intermediates", %{
    tmp_dir: tmp
  } do
    modules = [
      Argus.Test.Fixtures.CleansUpEnteringLoop,
      Argus.Test.Fixtures.LeaksEnteringLoop,
      Argus.Test.Fixtures.LeaksBesideAnotherLoop,
      Argus.Test.Fixtures.OtherLoop
    ]

    root =
      Debug.capture!(modules, :shutdown, Path.join(tmp, "bundle"),
        probes: ["traps_elsewhere", "enters_own_loop", "enters_loop_of.reaches"]
      )

    assert {:ok, expected} = Memo.analyze(modules, :shutdown)

    for {name, rows} <- expected do
      assert Debug.rows!(root, name, limit: 10_000).rows |> Enum.sort() == Enum.sort(rows)
    end

    never_runs = Debug.rows!(root, "cleanup_defect", where: [{"kind", "never_runs"}])

    assert Enum.map(never_runs.rows, &hd/1) |> Enum.sort() == [
             "Argus.Test.Fixtures.LeaksBesideAnotherLoop",
             "Argus.Test.Fixtures.LeaksEnteringLoop"
           ]

    own = Debug.rows!(root, "enters_own_loop")
    assert Enum.any?(own.rows, &(&1 == ["Argus.Test.Fixtures.CleansUpEnteringLoop:init/1"]))

    refute Enum.any?(
             own.rows,
             &(&1 == ["Argus.Test.Fixtures.LeaksBesideAnotherLoop:run_other/1"])
           )

    assert Debug.rows!(root, "traps_elsewhere").rows == [
             ["Argus.Test.Fixtures.LeaksBesideAnotherLoop:run_other/1"]
           ]

    assert [
             "Argus.Test.Fixtures.LeaksBesideAnotherLoop:run_other/1",
             "Argus.Test.Fixtures.OtherLoop"
           ] in Debug.rows!(root, "enters_loop_of.reaches").rows

    description = Debug.describe!(root, "enters_loop_of.reaches")
    assert Enum.map(description.fields, & &1["name"]) == ["func", "target"]
    assert Enum.any?(description.sources, &String.contains?(&1.text, ".comp SameProcessReach"))

    assert Enum.any?(
             Debug.describe!(root, "trap_exit").producers,
             &(&1["module"] == "Argus.Extractors.ErrorHandling")
           )

    location = Debug.locate!(root, "Argus.Test.Fixtures.CleansUpEnteringLoop:init/1")
    assert String.ends_with?(location.file, "test/fixtures/error_handling_fixture.ex")
    assert is_integer(location.line) and location.line > 0

    assert "instruction" in Debug.relations!(root)
    assert File.read!(Path.join(root, "facts/extraction_error.facts")) == ""
  end

  test "a moved bundle reruns copied custom includes after the original is deleted", %{
    tmp_dir: tmp
  } do
    root = custom_bundle(tmp)
    File.rm!(Path.join(tmp, "custom.dl"))
    moved = Path.join(tmp, "moved")
    File.rename!(root, moved)
    before = Debug.rows!(moved, "selected").rows
    run = Debug.solve!(moved)
    assert String.starts_with?(run, moved)
    assert before != []
    assert Debug.rows!(moved, "selected").rows == before
  end

  test "failed compilation leaves the previous successful run readable", %{tmp_dir: tmp} do
    root = custom_bundle(tmp)
    latest = File.read!(Path.join(root, "latest.json"))
    before = Debug.rows!(root, "selected").rows
    path = Path.join(root, Debug.manifest!(root)["program"])
    File.write!(path, "this is not datalog\n", [:append])

    assert_raise ArgumentError, ~r/could not compile/, fn -> Debug.solve!(root) end
    assert File.read!(Path.join(root, "latest.json")) == latest
    assert Debug.rows!(root, "selected").rows == before
  end

  test "a custom extractor's empty declared relation is written, not inferred from absence", %{
    tmp_dir: tmp
  } do
    root =
      custom_bundle(
        tmp,
        """
        .decl tutorial_site(func: symbol)
        .input tutorial_site
        .output tutorial_site
        """,
        extractors: [EmptyExtractor]
      )

    assert File.read!(Path.join(root, "facts/tutorial_site.facts")) == ""
    assert Debug.rows!(root, "tutorial_site").rows == []

    assert Enum.any?(
             Debug.describe!(root, "tutorial_site").producers,
             &(&1["module"] == "Argus.DebugTest.EmptyExtractor")
           )

    File.rm!(Debug.rows!(root, "tutorial_site", from: :facts).path)

    assert_raise ArgumentError, ~r/missing relation file/, fn ->
      Debug.rows!(root, "tutorial_site", from: :facts)
    end
  end

  test "failed restaging preserves extracted facts and the previous staged snapshot", %{
    tmp_dir: tmp
  } do
    root = custom_bundle(tmp)
    latest = File.read!(Path.join(root, "latest.json"))
    extracted = File.read!(Path.join(root, "facts/function_def.facts"))
    previous = Debug.rows!(root, "call_edge", from: :facts)
    staged = File.read!(previous.path)
    File.write!(Path.join(root, "rules/stage0.dl"), "not a program\n")

    assert_raise ArgumentError, ~r/derive stage 0/, fn ->
      Debug.solve!(root, restage: true)
    end

    assert File.read!(Path.join(root, "latest.json")) == latest
    assert File.read!(Path.join(root, "facts/function_def.facts")) == extracted
    refute File.exists?(Path.join(root, "facts/call_edge.facts"))
    assert File.read!(previous.path) == staged
    assert Debug.rows!(root, "call_edge", from: :facts).rows == previous.rows
  end

  test "an edited output declaration exposes its new column names", %{tmp_dir: tmp} do
    root = custom_bundle(tmp)
    previous = Debug.snapshot!(root)["directory"]
    original = Debug.rows!(root, "selected")
    path = Path.join(root, Debug.manifest!(root)["program"])
    File.write!(path, String.replace(File.read!(path), "selected(func:", "selected(caller:"))
    Debug.solve!(root)

    assert Debug.rows!(root, "selected", where: [{"caller", "not-present"}]).fields == ["caller"]
    assert Debug.rows!(root, "selected").rows != []
    assert Debug.rows!(root, "selected", run: previous).fields == ["func"]
    assert Debug.rows!(root, "selected", run: previous).rows == original.rows
    assert File.regular?(Path.join([root, previous, "run.json"]))

    assert Enum.all?(Debug.describe!(root, "selected", run: previous).sources, fn source ->
             String.starts_with?(source.path, previous <> "/rules/")
           end)
  end

  test "bounded rows use named columns, reject unknown filters and distinguish truncation", %{
    tmp_dir: tmp
  } do
    root = custom_bundle(tmp)
    table = Debug.rows!(root, "function_def", limit: 1)
    assert length(table.rows) == 1
    assert table.more?

    filtered = Debug.rows!(root, "function_def", where: [{"name", "init"}])
    assert Enum.all?(filtered.rows, &(Enum.at(&1, 2) == "init"))
    refute filtered.more?

    assert_raise ArgumentError, ~r/unknown column typo/, fn ->
      Debug.rows!(root, "function_def", where: [{"typo", "init"}])
    end

    assert_raise ArgumentError, ~r/limit must be positive/, fn ->
      Debug.rows!(root, "function_def", limit: 0)
    end

    assert_raise ArgumentError, ~r/offset must be non-negative/, fn ->
      Debug.rows!(root, "function_def", offset: -1)
    end
  end

  test "capture refuses an existing destination without changing its contents", %{tmp_dir: tmp} do
    root = custom_bundle(tmp)
    before = File.read!(Path.join(root, "bundle.json"))

    assert_raise ArgumentError, ~r/already exists/, fn ->
      Debug.capture!([Argus.Test.Fixtures.CleansUpEnteringLoop], :shutdown, root)
    end

    assert File.read!(Path.join(root, "bundle.json")) == before
  end

  test "an inline relation can be probed without editing its declaration", %{tmp_dir: tmp} do
    root =
      custom_bundle(
        tmp,
        """
        .decl intermediate(value: symbol) inline
        intermediate("kept").
        .decl caller_bound(value: symbol) inline
        caller_bound(x) :- x = x.
        .decl result(value: symbol)
        result(x) :- intermediate(x), caller_bound(x).
        .output result
        """,
        probes: ["intermediate"]
      )

    assert Debug.rows!(root, "intermediate").rows == [["kept"]]
    assert Debug.rows!(root, "result").rows == [["kept"]]
    assert File.read!(Path.join(root, Debug.manifest!(root)["program"])) =~ "inline"
  end

  test "CLI row output keeps headers and gives an actionable filter error", %{tmp_dir: tmp} do
    root = custom_bundle(tmp)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Argus.Debug.run(["rows", root, "function_def", "--where", "name=init"])
      end)

    assert output =~ "func\tmod\tname\tarity\texported"
    assert output =~ "CleansUpEnteringLoop:init/1"

    assert_raise Mix.Error, ~r/column=value/, fn ->
      Mix.Tasks.Argus.Debug.run(["rows", root, "function_def", "--where", "bad"])
    end
  end
end
