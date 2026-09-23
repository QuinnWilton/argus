defmodule Scry.AnalysisStoreTest do
  @moduledoc """
  A relation's rows are stringified once per change: the digest writes
  the text to the shared relation store, and the call graph's outputs
  are digested once per derivation, not once per analysis reading them.
  """

  use ExUnit.Case, async: false

  alias Scry.Test.{Graph, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  @store Path.join(System.tmp_dir!(), "scry_souffle/relations")

  setup_all do
    %{paths: Graph.compile_parity!(Path.join(System.tmp_dir!(), "scry_store_ebin"))}
  end

  test "a relation's digest names the file it stored", %{paths: paths} do
    # Whatever an earlier run stored goes first (a directory that needs
    # one regenerates it), so only this digest can have written it.
    @store |> Path.join("function_def_*.facts") |> Path.wildcard() |> Enum.each(&File.rm/1)

    db = Graph.new_db(paths)
    digest = Scry.Analysis.relation_digest(db, :function_def)

    path = Path.join(@store, "function_def_#{digest}.facts")
    assert File.exists?(path)
    assert path |> File.read!() |> :erlang.md5() |> Base.encode16(case: :lower) == digest
  end

  test "stage 0's outputs are digested once, whatever reads them", %{paths: paths} do
    db = Graph.new_db(paths)
    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)

    # Both read the call graph.
    for analysis <- [:blocking, :coupling], do: Scry.Analysis.analysis_facts_dir(db, analysis)

    digested = QueryLog.executions(log, :stage0_digest)
    assert :call_edge in digested
    assert digested == Enum.uniq(digested)
  end
end
