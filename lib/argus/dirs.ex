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

  The store's root is made by `Roux.Blob.open/1` alone (mode `0700`),
  which refuses one another user could have written (`Roux.Blob.TrustError`):
  what it holds is decoded as trusted, and so are the rules unpacked in
  it. Nothing else here makes it.
  """

  @doc """
  Whether anything outlives a run: false when `ARGUS_NO_CACHE` is set to
  anything but `""`, `"0"` or `"false"`, and every run then uses a
  temporary store of its own and keeps no manifest.
  """
  @spec keep?() :: boolean()
  def keep?, do: System.get_env("ARGUS_NO_CACHE", "") in ["", "0", "false"]

  @doc "The blob store's directory (`Argus.Graph.store_root/0`)."
  @spec store() :: Path.t()
  def store, do: Argus.Graph.store_root()

  @doc """
  Where an escript unpacks the Datalog rules it carries: the store's
  root opened first, so that it is made (and judged) as a store, never
  by the unpack's `mkdir -p`. Raises `Roux.Blob.TrustError` for a root
  another user could have written.
  """
  @spec dl() :: Path.t()
  def dl do
    %Roux.Blob{root: root} = Roux.Blob.open!(store())
    Path.join(root, "dl")
  end
end
