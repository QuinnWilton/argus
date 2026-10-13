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

  require Logger

  @doc """
  Whether anything outlives a run: false when `ARGUS_NO_CACHE` is set to
  anything but `""`, `"0"` or `"false"`, and every run then uses a
  temporary store of its own and keeps no manifest.
  """
  @spec keep?() :: boolean()
  def keep?, do: System.get_env("ARGUS_NO_CACHE", "") in ["", "0", "false"]

  @doc """
  The directory a user's caches go under: `$XDG_CACHE_HOME` when it is
  set and not empty, else `home_cache/0`.
  """
  @spec cache_home() :: Path.t()
  def cache_home do
    case System.get_env("XDG_CACHE_HOME") do
      dir when dir not in [nil, ""] -> Path.expand(dir)
      _ -> home_cache()
    end
  end

  @doc """
  `~/.cache`; without a home directory (`HOME` unset, as a service or a
  bare container may run), `argus-<uid>` under the system's temporary
  directory, so a run still keeps its caches. Each root argus keeps
  there is made owner-only, and refused when another user could have
  written it, wherever it is.
  """
  @spec home_cache() :: Path.t()
  def home_cache do
    case System.user_home() do
      home when home not in [nil, ""] -> Path.join(home, ".cache")
      _ -> Path.join(System.tmp_dir!(), "argus-#{uid()}")
    end
  end

  @doc "The user this VM runs as, by number (`id -u`), found once per VM."
  @spec uid() :: non_neg_integer()
  def uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        {out, 0} = System.cmd("id", ["-u"])
        uid = out |> String.trim() |> String.to_integer()
        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  @doc "The blob store's directory (`Argus.Graph.store_root/0`)."
  @spec store() :: Path.t()
  def store, do: Argus.Graph.store_root()

  @doc """
  The blob store at `store/0`, opened. One argus cannot make (a home it
  cannot write, as a build sandbox's) is no reason to fail a run: it
  gets a temporary store instead, and keeps nothing for the next, which
  is said once per VM. Raises `Roux.Blob.TrustError` for a store another
  user could have written.
  """
  @spec open_store() :: Roux.Blob.t()
  def open_store do
    root = store()

    case Roux.Blob.open(root) do
      {:ok, store} ->
        store

      {:error, reason} when is_atom(reason) ->
        unkept(root, reason)
        Roux.Blob.temporary()

      {:error, _} ->
        Roux.Blob.open!(root)
    end
  end

  defp unkept(root, reason) do
    unless :persistent_term.get({__MODULE__, :unkept, root}, false) do
      :persistent_term.put({__MODULE__, :unkept, root}, true)

      Logger.warning(
        "argus: cannot keep its cache in #{root} (#{:file.format_error(reason)}), so a run " <>
          "keeps nothing for the next: set ARGUS_CACHE_DIR to a directory you can write"
      )
    end
  end

  @doc """
  Where an escript unpacks the Datalog rules it carries: the store's
  root opened first (`open_store/0`), so that it is made (and judged) as
  a store, never by the unpack's `mkdir -p`.
  """
  @spec dl() :: Path.t()
  def dl do
    %Roux.Blob{root: root} = open_store()
    Path.join(root, "dl")
  end
end
