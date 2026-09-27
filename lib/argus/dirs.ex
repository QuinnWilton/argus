defmodule Argus.Dirs do
  @moduledoc """
  Where argus keeps what outlives a run on this machine.

  The blob store (`store/0`) is one per user, shared by every project,
  worktree and frontend: `$ARGUS_CACHE_DIR` when set, else
  `$XDG_CACHE_HOME/argus/store`, else `~/.cache/argus/store`. A
  project's own state (its manifest) lives in the project
  (`Argus.Project`'s `state_dir`); only content-addressed values, which
  any run may share, live here.

  The Datalog rules an escript carries are unpacked under the store
  (`dl/0`), one directory per tree of rules (`Argus.Dl`).
  """

  @doc "The blob store's directory (`Argus.Graph.store_root/0`)."
  @spec store() :: Path.t()
  def store, do: Argus.Graph.store_root()

  @doc "Where an escript unpacks the Datalog rules it carries."
  @spec dl() :: Path.t()
  def dl, do: Path.join(store(), "dl")
end
