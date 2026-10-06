defmodule Argus.Debug.ExplorerTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Argus.Debug
  alias Argus.Debug.Explorer
  alias Argus.Debug.Explorer.Bundle

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "bundle")
    source = Path.join(tmp, "sample.ex")
    File.write!(source, "defmodule Sample do\n  def run, do: :ok\nend\n")
    fields = [%{"name" => "id", "type" => "symbol"}, %{"name" => "kind", "type" => "symbol"}]

    rules =
      ".decl reports(id: symbol, kind: symbol)\nreports(\"Sample:run/0#1\", \"leak\").\n.output reports\n"

    manifest = %{
      "version" => 1,
      "analysis" => "tutorial",
      "program" => "rules/tutorial.dl",
      "solver" => "test solver",
      "priors" => "none",
      "sources" => %{"Sample" => source},
      "schema" => %{"observed" => %{"fields" => fields, "doc" => "Observed operations"}},
      "outputs" => %{"reports" => %{"fields" => fields, "doc" => "Operations needing attention"}},
      "producers" => %{"observed" => [%{"module" => "ExampleExtractor", "file" => source}]}
    }

    File.mkdir_p!(Path.join(root, "rules"))
    File.mkdir_p!(Path.join(root, "facts"))
    File.write!(Path.join(root, "bundle.json"), JSON.encode!(manifest))
    File.write!(Path.join(root, "rules/tutorial.dl"), rules)
    File.write!(Path.join(root, "facts/line_info.facts"), "Sample:run/0#1\t2\n")

    latest = %{
      "directory" => "runs/new",
      "columns" => %{"reports" => fields, "observed" => fields, "hidden" => fields},
      "outputs" => ["reports"],
      "probes" => []
    }

    old = %{
      latest
      | "directory" => "runs/old",
        "columns" => %{"reports" => [%{"name" => "caller", "type" => "symbol"}]}
    }

    for snapshot <- [latest, old] do
      dir = Path.join(root, snapshot["directory"])
      File.mkdir_p!(Path.join(dir, "facts"))
      File.mkdir_p!(Path.join(dir, "rules"))
      File.write!(Path.join(dir, "run.json"), JSON.encode!(snapshot))

      File.write!(
        Path.join(dir, "rules/tutorial.dl"),
        if(snapshot == old, do: ".decl reports(caller: symbol)\n// OLD RULE\n", else: rules)
      )

      File.write!(Path.join(dir, "facts/observed.facts"), "")
    end

    rows = for n <- 1..45, do: ["Sample:run/0##{n}", if(rem(n, 2) == 0, do: "safe", else: "leak")]
    File.write!(Path.join(root, "runs/new/reports.csv"), Argus.Tsv.encode(rows))
    File.write!(Path.join(root, "runs/old/reports.csv"), "Old:run/0\n")
    File.write!(Path.join(root, "latest.json"), JSON.encode!(latest))
    %{root: root, latest: latest}
  end

  defp start(root, size \\ {120, 30}) do
    session = Breeze.Test.start!(Explorer, start_opts: [root: root], size: size)
    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)
    session
  end

  # Settle the newly rendered focus/implicit tree between user interactions.
  defp press(session, key) do
    result = Breeze.Test.input(session, key)
    unless match?({:stop, _, _}, result), do: Breeze.Test.render_text!(session)
    result
  end

  defp search(session, query) do
    press(session, "/")
    for key <- String.graphemes(query), do: press(session, key)
    press(session, "Enter")
  end

  test "search, filter, paging, and full row fields work through terminal input", %{root: root} do
    before = contents(root)
    session = start(root)
    assert Breeze.Test.render_text!(session) =~ "Operations needing attention"
    press(session, "Enter")
    press(session, "n")
    assert Breeze.Test.render_text!(session) =~ "Page 2"
    press(session, "N")
    press(session, "f")
    for key <- String.graphemes("kind=leak"), do: press(session, key)
    press(session, "Enter")
    screen = Breeze.Test.render_text!(session)
    assert screen =~ "kind=leak"
    assert screen =~ "Sample:run/0#1 | leak"
    refute screen =~ "| safe"
    press(session, "n")
    assert Breeze.Test.render_text!(session) =~ "Sample:run/0#41 | leak"
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "id = Sample:run/0#41"
    press(session, "Escape")
    press(session, "x")
    search(session, "OBSERVED")
    screen = Breeze.Test.render_text!(session)
    assert screen =~ "Relations (1)"
    assert screen =~ "No matching rows"
    press(session, "d")
    assert Breeze.Test.render_text!(session) =~ "ExampleExtractor"
    assert contents(root) == before
  end

  test "row identifiers and rule references open source and Escape returns", %{root: root} do
    session = start(root)
    press(session, "Enter")
    press(session, "Enter")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "def run, do: :ok"
    assert Breeze.Test.render_text!(session) =~ "> 2"
    press(session, "Escape")
    assert Breeze.Test.render_text!(session) =~ "id = Sample:run/0#1"
    press(session, "ArrowDown")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "Full field value"
    assert Breeze.Test.render_text!(session) =~ "leak"
    press(session, "Escape")
    press(session, "Escape")
    press(session, "r")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ ".decl reports"
  end

  test "invalid filters and missing files keep the explorer usable", %{root: root} do
    session = start(root)
    press(session, "f")
    for key <- String.graphemes("typo=leak"), do: press(session, key)
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "unknown column typo"
    assert Breeze.Test.render_text!(session) =~ "Sample:run/0#1 | leak"
    press(session, "x")
    search(session, "hidden")
    assert Breeze.Test.render_text!(session) =~ "missing relation file"
    press(session, "r")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "No matching rule references"
  end

  test "historical selection uses that run's columns and rules", %{root: root} do
    session = start(root)
    press(session, "t")
    runs = Debug.runs!(root)
    index = Enum.find_index(runs, &(&1.directory == "runs/old"))
    if index > 0, do: Enum.each(1..index, fn _ -> press(session, "ArrowDown") end)
    press(session, "Enter")
    screen = Breeze.Test.render_text!(session)
    assert screen =~ "retained run"
    assert screen =~ "caller"
    assert screen =~ "Old:run/0"
    press(session, "r")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "OLD RULE"
    press(session, "Escape")
    press(session, "R")
    assert Breeze.Test.render_text!(session) =~ "Sample:run/0#1"
  end

  test "narrow terminals switch between catalog and detail, and help remains available", %{
    root: root
  } do
    session = start(root, {40, 16})
    assert Breeze.Test.render_text!(session) =~ "Relations"
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "Page 1"
    press(session, "Escape")
    assert Breeze.Test.render_text!(session) =~ "Relations"
    session = Breeze.Test.resize(session, {80, 24})
    press(session, "b")
    assert Breeze.Test.render_text!(session) =~ "Analysis: tutorial"
    press(session, "?")
    assert Breeze.Test.render_text!(session) =~ "Explore an Argus debug bundle"
    press(session, "Escape")
    assert {:stop, _, _} = press(session, "q")
  end

  test "older metadata, missing source and unsafe terminal text are handled explicitly", %{
    root: root
  } do
    File.rm!(Path.join(root, "runs/old/run.json"))

    assert_raise ArgumentError, ~r/no successful run metadata/, fn ->
      Debug.snapshot!(root, run: "runs/old")
    end

    assert_raise ArgumentError, ~r/expected a run directory/, fn ->
      Debug.snapshot!(root, run: "../other")
    end

    assert Debug.rows!(root, "reports", where: [{"kind", "leak"}], offset: 20, limit: 2).rows == [
             ["Sample:run/0#41", "leak"],
             ["Sample:run/0#43", "leak"]
           ]

    File.rm!(Path.join(root, "runs/new/run.json"))
    assert Debug.snapshot!(root, run: "runs/new")["directory"] == "runs/new"
    assert Bundle.text("a\e[31mb\x07") == "a�[31mb�"
    session = start(root)
    File.rm!(Path.join(root, "facts/line_info.facts"))
    press(session, "Enter")
    press(session, "Enter")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "line_info"
  end

  defp contents(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  test "zero-column true relations can be opened without an empty field selection", %{
    root: root,
    latest: latest
  } do
    latest = put_in(latest, ["columns", "reports"], [])
    File.write!(Path.join(root, "latest.json"), JSON.encode!(latest))
    File.write!(Path.join(root, "runs/new/reports.csv"), "\n")
    session = start(root)
    press(session, "Enter")
    press(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "True (zero-column relation)"
    press(session, "Escape")
    assert Breeze.Test.render_text!(session) =~ "Page 1"
  end
end
