defmodule Argus.Graph.StageOutputTest do
  @moduledoc """
  A stage's output that is not there when the graph adopts it is an
  error naming the relation and its file, never an empty relation: read
  as one, stage 0's call graph came back empty and every analysis that
  reads it lost its findings without a word.

  In this module's peer (`Argus.Test.Peer`): `PATH` is VM-wide, and the
  solver here is the real one behind a script.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Graph, Peer}

  @moduletag :souffle
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup_all do
    %{paths: Graph.parity!(), peer: Peer.start!()}
  end

  # The real solver, except that once stage 0 has written its outputs,
  # its call graph is a link to nothing: listed among them, so argus
  # publishes the stage, and gone for whoever opens it. It stands in for
  # a file taken from the directory between the solver's writing it and
  # the store's adopting it.
  defp unreadable_call_edge!(dir) do
    real = System.find_executable("souffle")
    wrapper = Path.join(dir, "souffle")

    File.write!(wrapper, """
    #!/bin/sh
    case "$1" in --show*|--version) exec #{real} "$@";; esac
    out=""
    prev=""
    last=""
    for arg in "$@"; do
      if [ "$prev" = "-D" ]; then out="$arg"; fi
      prev="$arg"
      last="$arg"
    done
    #{real} "$@" || exit $?
    case "$last" in
      *stage0.dl) rm -f "$out/call_edge.facts"; ln -s "$out/gone" "$out/call_edge.facts" ;;
    esac
    """)

    File.chmod!(wrapper, 0o755)
  end

  test "stage 0's call graph gone when read back is an error naming it, not an empty graph", %{
    tmp_dir: dir,
    paths: paths,
    peer: peer
  } do
    Peer.run(peer, fn -> unreadable_stage0(dir, paths) end)
  end

  defp unreadable_stage0(dir, paths) do
    unreadable_call_edge!(dir)
    original = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original)

    try do
      # A store of its own: a solve kept by another test would not run
      # the solver at all.
      db = Graph.new_db(paths, store: :temporary)

      assert {:error, %Argus.MissingRelationError{} = error} =
               Argus.Graph.Solve.stage(db, {:test, :stage0})

      assert error.relation == "call_edge"
      assert error.reason == :enoent
      assert Path.basename(error.path) == "call_edge.facts"

      # And every analysis reading the call graph degrades with it.
      assert {:error, %Argus.MissingRelationError{relation: "call_edge"}} =
               Argus.Graph.Findings.results(db, :test, :coupling)
    after
      System.put_env("PATH", original)
    end
  end
end
