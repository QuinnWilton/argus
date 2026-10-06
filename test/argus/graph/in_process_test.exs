defmodule Argus.Graph.InProcessTest do
  @moduledoc """
  The relations only the in-process passes read
  (`Argus.Schema.in_process_only/0`) are no built-in program's input, and
  `module_facts` leaves them out. A program of the caller's own that reads
  one gets the base's rows, extracted for it (`module_in_process`), whether
  it is solved on the graph or over the directory `extract_facts/3` writes
  for it; a directory written for other analyses has no file for them, so
  the program fails there rather than solving over an empty relation.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Test.Files

  @moduletag :souffle
  @moduletag :tmp_dir

  @modules [Argus.Test.Fixtures.PidFlow.Hub, Argus.Test.Fixtures.PidFlow.Listener]

  setup %{tmp_dir: tmp} do
    path = Path.join(tmp, "steps.dl")

    File.write!(path, """
    .include "#{Path.join(:code.priv_dir(:argus_beam), "dl/base.dl")}"

    .decl op(id: symbol, func: symbol, idx: number, op: symbol)
    .output op
    op(id, func, idx, o) :- instruction(id, func, idx, o).

    .decl step(from: symbol, to: symbol)
    .output step
    step(a, b) :- next(a, b).
    """)

    # A store of its own: the base runs, never found from another test.
    %{program: path, store: Path.join(tmp, "store")}
  end

  # The pipeline's own rows of a relation over the modules, sorted.
  defp pipeline_rows(relation) do
    {:ok, facts} = Argus.Pipeline.extract(@modules, extractors: [])
    facts |> Map.get(relation, []) |> Enum.sort()
  end

  defp file_rows(dir, relation) do
    dir |> Path.join("#{relation}.facts") |> File.read!() |> Argus.Tsv.decode() |> Enum.sort()
  end

  test "a program of the caller's own solves over the base's rows", %{program: path, store: store} do
    assert {:ok, results} = Argus.analyze(@modules, {:custom, path}, store: store)

    assert length(results["op"]) == length(pipeline_rows(:instruction))
    assert length(results["step"]) == length(pipeline_rows(:next))
    assert results["op"] != []
  end

  test "extract_facts writes them for a program that reads them, and no other",
       %{program: path, store: store} do
    {:ok, dir} = Analysis.extract_facts(@modules, [{:custom, path}], store: store)

    try do
      assert file_rows(dir, :instruction) == pipeline_rows(:instruction)
      assert file_rows(dir, :next) == pipeline_rows(:next)
      assert {:ok, results} = Analysis.run_rules(dir, {:custom, path})
      assert length(results["op"]) == length(pipeline_rows(:instruction))

      # The in-process relations the program does not read have no file.
      refute File.exists?(Path.join(dir, "jump.facts"))
    after
      Files.rm_rf!(Path.dirname(dir))
    end
  end

  test "a directory made for other analyses has no file for them, and the program fails over it",
       %{program: path, store: store} do
    {:ok, dir} = Analysis.extract_facts(@modules, [:mailbox], store: store)

    try do
      for relation <- Argus.Schema.in_process_only(),
          do: refute(File.exists?(Path.join(dir, "#{relation}.facts")), "#{relation}.facts")

      assert {:error, _reason} = Analysis.run_rules(dir, {:custom, path})
    after
      Files.rm_rf!(Path.dirname(dir))
    end
  end
end
