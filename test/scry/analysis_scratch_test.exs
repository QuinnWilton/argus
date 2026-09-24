defmodule Scry.AnalysisScratchTest do
  @moduledoc """
  The scratch root's pruning bounds the fact directories without ever
  taking the shared relation store with them.
  """

  # The scratch root is shared by every scry in a temp dir, and this
  # prunes it: in this module's peer (`Scry.Test.Peer`), whose root is
  # its own.
  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.Peer

  test "the relation store survives pruning, however old its directory" do
    Peer.run(Peer.start!(), fn -> relation_store_survives() end)
  end

  defp relation_store_survives do
    root = Path.join(System.tmp_dir!(), "scry_souffle")
    relations = Path.join(root, "relations")
    File.mkdir_p!(relations)
    marker = Path.join(relations, "scry_prune_test_#{System.unique_integer([:positive])}.facts")
    File.write!(marker, "a\tb\n")

    # Older than every fact directory, and more than a window's worth of
    # those after it.
    File.touch!(relations, 1)

    fresh =
      for n <- 1..30 do
        dir = Path.join(root, "scry_prune_test_#{n}")
        File.mkdir_p!(dir)
        dir
      end

    try do
      :ok = Scry.Analysis.prune_scratch()

      assert File.dir?(relations)
      assert File.exists?(marker)
      # The window still bounds the fact directories.
      assert length(File.ls!(root)) <= 25
    after
      File.rm(marker)
      Enum.each(fresh, &File.rm_rf/1)
    end
  end
end
