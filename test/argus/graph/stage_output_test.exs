defmodule Argus.Graph.StageOutputTest do
  @moduledoc """
  A stage's output that is not there when the graph adopts it is an
  error naming the relation and its file, never an empty relation: read
  as one, stage 0's call graph came back empty and every analysis that
  reads it lost its findings without a word.

  In this module's peer (`Argus.Test.Peer`): the engine here is the real
  one behind a proxy (`Argus.Test.FailingEngine`), in a cache root named
  by a VM-wide variable.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Graph.Solve
  alias Argus.Test.{FailingEngine, Graph, Peer}

  @moduletag :flowlog
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup_all do
    # Two communicating servers provide a nonempty call graph. The full
    # fixture set belongs to the incremental/fresh parity test.
    paths =
      Map.new(
        [Argus.Test.Fixtures.PidFlow.Hub, Argus.Test.Fixtures.PidFlow.Listener],
        &{&1, &1 |> :code.which() |> List.to_string()}
      )

    %{paths: paths, peer: Peer.start!()}
  end

  # The real engine, except that once a commit has written its outputs,
  # its call graph is a link to nothing: listed among them, so argus
  # adopts it, and gone for whoever opens it. It stands in for a file
  # taken from the directory between the engine's writing it and the
  # store's adopting it.
  defp unreadable_call_edge(real) do
    FailingEngine.proxy(real, "", """
    if [ -e "$out/call_edge.facts" ]; then
      rm -f "$out/call_edge.facts"; ln -s "$out/gone" "$out/call_edge.facts"
    fi
    """)
  end

  test "stage 0's call graph gone when read back is an error naming it, not an empty graph", %{
    tmp_dir: dir,
    paths: paths,
    peer: peer
  } do
    Peer.run(peer, fn -> unreadable_stage0(dir, paths) end)
  end

  defp unreadable_stage0(_dir, paths) do
    healthy = Graph.new_db(paths, store: :temporary)

    try do
      assert {:ok, %{outputs: outputs}} = Solve.stage(healthy, {:test, :stage0})

      assert {:ok, %{"call_edge" => [_ | _]}} =
               Solve.read_outputs(healthy, outputs, ["call_edge.facts"])
    after
      Roux.Database.shutdown(healthy)
    end

    FailingEngine.with(
      "stage0.dl",
      fn ->
        # A store of its own: a solve kept by another test would not run
        # the engine at all.
        db = Graph.new_db(paths, store: :temporary)

        try do
          assert {:error, %Argus.MissingRelationError{} = error} =
                   Solve.stage(db, {:test, :stage0})

          assert error.relation == "call_edge"
          assert error.reason == :enoent
          assert Path.basename(error.path) == "call_edge.facts"

          # An analysis reading the call graph degrades with it.
          assert {:error, %Argus.MissingRelationError{relation: "call_edge"}} =
                   Argus.Graph.Findings.results(db, :test, :coupling)
        after
          Roux.Database.shutdown(db)
        end
      end,
      stub: &unreadable_call_edge/1
    )
  end
end
