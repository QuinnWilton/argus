defmodule Scry.AnalysisStoreTest do
  @moduledoc """
  A relation's rows are stringified once per change: the digest writes
  the text to the shared relation store, and the call graph's outputs
  are digested once per derivation, not once per analysis reading them.

  In this module's peer (`Scry.Test.Peer`), whose scratch root is its
  own: the first test empties part of the relation store, which a solve
  elsewhere could be reading, and the query log's telemetry handlers are
  VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Graph, Peer, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  setup_all do
    %{paths: Graph.parity!(), peer: Peer.start!()}
  end

  test "a relation's digest names the file it stored", %{paths: paths, peer: peer} do
    Peer.run(peer, fn ->
      store = Path.join(System.tmp_dir!(), "scry_souffle/relations")

      # Whatever an earlier run stored goes first (a directory that needs
      # one regenerates it), so only this digest can have written it.
      store |> Path.join("function_def_*.facts") |> Path.wildcard() |> Enum.each(&File.rm/1)

      db = Graph.new_db(Graph.use_parity!(paths))
      digest = Scry.Analysis.relation_digest(db, :function_def)
      Roux.Database.shutdown(db)

      path = Path.join(store, "function_def_#{digest}.facts")
      assert File.exists?(path)
      assert path |> File.read!() |> :erlang.md5() |> Base.encode16(case: :lower) == digest
    end)
  end

  test "stage 0's outputs are digested once, whatever reads them", %{paths: paths, peer: peer} do
    Peer.run(peer, fn ->
      db = Graph.new_db(Graph.use_parity!(paths))
      log = QueryLog.start()

      try do
        # Both read the call graph.
        for analysis <- [:blocking, :coupling], do: Scry.Analysis.analysis_facts_dir(db, analysis)

        digested = QueryLog.executions(log, :stage0_digest)
        assert :call_edge in digested
        assert digested == Enum.uniq(digested)
      after
        QueryLog.detach(log)
        Roux.Database.shutdown(db)
      end
    end)
  end
end
