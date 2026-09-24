defmodule Argus.Cache do
  @moduledoc """
  A store of extraction and solve results on disk, keyed by content, so
  a run redoes only the work an edit invalidates.

  A store is a directory; `Argus.Corpus` keeps one per checkout, the
  test suite one under `_build/test`, and a caller of
  `Argus.run_analyses/2`, `Argus.analyze/3` or
  `Argus.Analysis.extract_facts/3` names its own with `cache:`. Inside:

    * `shards/` — each producer's facts (`Argus.Cache.Facts`): the rows
      `:base` or one extractor made of a set of beams, keyed by the
      beams, the code the producer runs (`Argus.Cache.Code`), the
      runtime and the options that shape its rows. An edit to one
      extractor re-extracts that extractor's shard alone.
    * `solves/` — each Souffle solve's outputs (`Argus.Souffle.Cache`),
      keyed by the program with its includes, the solver, and the
      content of exactly the relation files the program reads. A solve
      whose inputs came out the same after an edit is not run again, so
      a change that leaves stage 0's output unchanged re-solves nothing
      downstream of it.
    * `programs/` — the relations each program reads, as Souffle
      resolves them (`Argus.Souffle.input_relations/2`), kept so a warm
      run starts no solver at all.

  ## Entries

  An entry is named `<group>-<key>`, `key` 64 hex digits; the group is
  what the key is a version of (a producer over a set of beams, a
  program over a set of facts) and is what retention counts in
  (`stale/2`). An entry is written under a staging name beside it
  (`<group>-<key>.<os pid>.<n>`) and renamed into place: complete or
  absent, never half-written. A second writer of the same key loses
  the rename and discards its copy. The files inside are read-only: a
  run links them into a directory of its own, and nothing it does to
  that directory reaches back into the store. A hit touches its entry,
  which is what `stale/2` reads to tell an entry in use from one nobody
  will read again.

  ## Turning it off

  `ARGUS_NO_CACHE=1` makes every store a no-op: nothing is read from one
  and nothing kept, and each run extracts and solves in scratch space as
  it would without `cache:`. It is the check that a result does not rest
  on something a key missed — after changing how a key is made, when an
  answer looks stale, and once before a release.
  """

  @typedoc "What `stale/2` spares; see there."
  @type prune_option ::
          {:keep, [String.t()]} | {:recent, non_neg_integer()} | {:max_age, pos_integer()}

  @subdirs ~w(shards solves programs)

  # Always spared: an entry touched within the hour may be one a run
  # beside this one is reading.
  @live_seconds 60 * 60
  @orphaned_staging_seconds 24 * 60 * 60
  @keep_recent 3

  @doc """
  Whether stores are used at all: false when `ARGUS_NO_CACHE` is set to
  anything but `""`, `"0"` or `"false"`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("ARGUS_NO_CACHE", "") in ["", "0", "false"]
  end

  @doc """
  The store an option list names under `:cache`, or nil when it names
  none or stores are off (`enabled?/0`).
  """
  @spec store(keyword()) :: Path.t() | nil
  def store(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      root when is_binary(root) ->
        if enabled?(), do: Path.expand(root), else: nil

      other ->
        raise ArgumentError, ":cache must be a directory path, got: #{inspect(other)}"
    end
  end

  @doc "One of the store's directories: `:shards`, `:solves` or `:programs`."
  @spec dir(Path.t(), :shards | :solves | :programs) :: Path.t()
  def dir(root, kind) when kind in [:shards, :solves, :programs],
    do: Path.join(root, Atom.to_string(kind))

  @doc """
  A kept entry: `{:ok, path}` (touched, so a pruner sees it in use) or
  `:miss`.
  """
  @spec fetch(Path.t()) :: {:ok, Path.t()} | :miss
  def fetch(entry) do
    if File.exists?(entry) do
      File.touch(entry)
      {:ok, entry}
    else
      :miss
    end
  end

  @doc "A fresh staging directory for an entry that will be kept at `entry`."
  @spec staging(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def staging(entry) do
    staging = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    case mkdir(staging) do
      :ok -> {:ok, staging}
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  @doc false
  # A directory whose parent is most often there already: one `mkdir`,
  # and the parents made only when it says they are missing. A cold run
  # makes thousands of these, and `File.mkdir_p/1` asks after each
  # parent first.
  @spec mkdir(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir(dir) do
    case File.mkdir(dir) do
      :ok ->
        :ok

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(dir)) do
          case File.mkdir(dir) do
            :ok -> :ok
            {:error, :eexist} -> :ok
            {:error, _} = error -> error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Installs a finished staging directory (or file) as `entry`, its files
  made read-only first — `names`, the files the caller wrote into it,
  or every file it holds. Another writer that installed the same key
  first wins, and this copy is discarded; either way `entry` holds the
  result afterwards. Any other failure leaves `staging` in place for
  the caller.
  """
  @spec install(Path.t(), Path.t(), [String.t()] | nil) :: :ok | {:error, File.posix()}
  def install(staging, entry, names \\ nil) do
    read_only(staging, names)

    case File.rename(staging, entry) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :enotempty, :eisdir] ->
        File.rm_rf(staging)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp read_only(path, nil) do
    case File.ls(path) do
      {:ok, names} -> read_only(path, names)
      {:error, :enotdir} -> File.chmod(path, 0o444)
      {:error, _} -> :ok
    end
  end

  defp read_only(path, names), do: Enum.each(names, &File.chmod(Path.join(path, &1), 0o444))

  @doc """
  The entries of a store (its `shards/`, `solves/` and `programs/`)
  that `prune/2` removes. Within each group (`<group>-<key>`, see the
  moduledoc) an entry goes once it has been untouched for an hour and
  is not among the `recent:` most recently touched of its group
  (default 3), or — with `max_age:` seconds — once it has been
  untouched that long, however recent. `keep:` names entries never
  removed. A staging name untouched for a day is a crashed writer's,
  and goes too, as does a run's scratch directory under `work/`.

  The hour is how long an entry is presumed in use: a hit touches it.
  The `recent:` entries are the baselines: a run before a change and
  one after it both stay warm, however long the change took.
  """
  @spec stale(Path.t(), [prune_option()]) :: [Path.t()]
  def stale(root, opts \\ []) do
    # A run's scratch directory (`work/<os pid>-<n>`) is a crashed run's
    # once a day has passed, as a staging name is.
    work =
      stale_entries(Path.join(root, "work"), [], fn name, _type ->
        if Regex.match?(~r/^\d+-\d+$/, name), do: :staging
      end)

    @subdirs
    |> Enum.flat_map(&stale_entries(Path.join(root, &1), opts, fn name, _type -> kind(name) end))
    |> Kernel.++(work)
    |> Enum.sort()
  end

  @doc "Removes `stale/2`; the paths it removed."
  @spec prune(Path.t(), [prune_option()]) :: [Path.t()]
  def prune(root, opts \\ []) do
    stale = stale(root, opts)
    Enum.each(stale, &File.rm_rf!/1)
    stale
  end

  @doc false
  # `stale/2`'s policy over one directory, each entry's kind given by
  # `kind_of.(name, file_type)`: `{:installed, group}`, `:staging` or nil
  # (not an entry).
  @spec stale_entries(Path.t(), [prune_option()], (String.t(), atom() -> term())) :: [Path.t()]
  def stale_entries(dir, opts, kind_of) do
    keep = opts |> Keyword.get(:keep, []) |> List.wrap()
    recent = Keyword.get(opts, :recent, @keep_recent)
    max_age = Keyword.get(opts, :max_age)
    now = System.os_time(:second)

    entries =
      for name <- ls(dir),
          path = Path.join(dir, name),
          {:ok, %File.Stat{mtime: touched, type: type}} <- [File.lstat(path, time: :posix)],
          kind = kind_of.(name, type),
          kind != nil,
          do: {kind, name, path, now - touched}

    stale_installed =
      for(
        {{:installed, group}, name, path, age} <- entries,
        name not in keep,
        age > @live_seconds,
        do: {group, age, path}
      )
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))
      |> Enum.flat_map(fn {_group, aged} ->
        {recent_ones, older} = aged |> Enum.sort() |> Enum.split(recent)

        expired =
          if max_age, do: Enum.filter(recent_ones, fn {age, _} -> age > max_age end), else: []

        Enum.map(older ++ expired, &elem(&1, 1))
      end)

    orphaned =
      for {:staging, _name, path, age} <- entries, age > @orphaned_staging_seconds, do: path

    Enum.sort(stale_installed ++ orphaned)
  end

  # `<group>-<key>` or its staging name `<group>-<key>.<pid>.<n>`.
  defp kind(name) do
    case Regex.run(~r/^(.+)-[0-9a-f]{64}(\.\d+\.\d+)?$/, name) do
      [_, group] -> {:installed, group}
      [_, _group, _staging] -> :staging
      nil -> nil
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  @doc false
  # SHA-256 of `parts`, each length-prefixed, as lowercase hex: every
  # key in the store.
  @spec key([binary()]) :: String.t()
  def key(parts) do
    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), fn part, hash ->
      :crypto.hash_update(hash, <<byte_size(part)::64>> <> part)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc false
  # SHA-256 of a file's bytes, as lowercase hex, read in chunks.
  @spec file_digest(Path.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def file_digest(path) do
    case File.open(path, [:read, :raw, :binary, {:read_ahead, 1_048_576}]) do
      {:ok, device} ->
        try do
          hash = hash_device(device, :crypto.hash_init(:sha256))
          {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
        after
          File.close(device)
        end

      {:error, _} = error ->
        error
    end
  end

  defp hash_device(device, hash) do
    case :file.read(device, 1_048_576) do
      {:ok, data} -> hash_device(device, :crypto.hash_update(hash, data))
      :eof -> hash
    end
  end
end
