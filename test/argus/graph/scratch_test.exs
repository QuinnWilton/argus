defmodule Argus.Graph.ScratchTest do
  @moduledoc """
  The scratch root's pruning takes only what a dead owner left in
  `work/`, and bounds the shared relation store without ever taking the
  store itself.
  """

  # The scratch root is shared by every scry in a temp dir, and this
  # prunes it: in this module's peer (`Argus.Test.Peer`), whose root is
  # its own.
  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Graph, Peer}

  setup_all do
    %{peer: Peer.start!()}
  end

  test "a prune takes a directory abandoned for a day, never a fresh one or the relation store",
       %{peer: peer} do
    Peer.run(peer, fn -> prunes_abandoned() end)
  end

  defp prunes_abandoned do
    root = Path.join(System.tmp_dir!(), "scry_scratch")
    relations = Path.join(root, "relations")
    File.mkdir_p!(relations)
    marker = Path.join(relations, "scry_prune_test_#{System.unique_integer([:positive])}.facts")
    File.write!(marker, "a\tb\n")
    # Older than any directory of work.
    File.touch!(relations, 1)

    day = 24 * 60 * 60
    now = System.os_time(:second)
    work = Path.join(root, "work")
    abandoned = Path.join(work, "stage0-1-1")
    fresh = Path.join(work, "stage0-1-2")
    busy = Path.join(work, "points_to-1-3")

    for {dir, age} <- [{abandoned, day + 60}, {fresh, 0}, {busy, day - 60}] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "call_edge.facts"), "")
      File.touch!(dir, now - age)
    end

    try do
      :ok = Argus.Graph.prune_scratch()

      assert File.exists?(marker)
      refute File.exists?(abandoned)
      assert File.dir?(fresh)
      assert File.dir?(busy)
    after
      File.rm(marker)
      Enum.each([fresh, busy], &File.rm_rf/1)
    end
  end

  @tag :souffle
  test "a solve and the stages it reads leave no directory behind", %{peer: peer} do
    paths = Graph.parity!()
    Peer.run(peer, fn -> leaves_nothing(paths) end)
  end

  defp leaves_nothing(paths) do
    db = Graph.new_db(Graph.use_parity!(paths))
    work = Path.join([System.tmp_dir!(), "scry_scratch", "work"])
    before = if File.dir?(work), do: File.ls!(work), else: []

    # Mailbox reads both stages.
    assert {:ok, _outputs} = Argus.Graph.souffle_solve(db, :mailbox)
    assert File.ls!(work) -- before == []
  end
end
