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
      runtime, the options that shape its rows, and what it read
      outside that code — the schema entries (`Argus.Cache.Reads`), the
      specs of modules on the code path. An edit to one extractor
      re-extracts that extractor's shard alone.
    * `reads/` — for each producer's key before its reads, the reads
      its last extraction made (names only): what a lookup reads again
      to name the entry. Entries are never replaced, so a run reading
      one is never pulled from under by a run keyed on other reads.
    * `solves/` — each Souffle solve's outputs (`Argus.Souffle.Cache`),
      keyed by the program with its includes, the solver, and the
      content of exactly the relation files the program reads. A solve
      whose inputs came out the same after an edit is not run again, so
      a change that leaves stage 0's output unchanged re-solves nothing
      downstream of it.
    * `programs/` — the relations each program reads, as Souffle
      resolves them (`Argus.Souffle.input_relations/2`), and the
      solver's version under a stamp of its binary
      (`Argus.Souffle.Cache.version/2`), kept so a warm run starts no
      solver at all.
    * `ebins/` — the hashes of each dependency ebin's beams under a
      stamp of their stats (`Argus.Specs.environment_digest/1`), so a
      fresh VM keys the specs extractor without reading every beam.
    * `bases/` — each module's base for a set of beams
      (`Argus.Pipeline.Base`: its disassembly, decoded facts,
      control-flow graphs and reaching definitions), keyed by the beams,
      the base's code, the runtime and what computing them read of the
      schema, so an extractor extracted again after an edit to it runs
      over them instead of computing them.

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

  A prune removes an entry the same way it was installed: renamed out
  of its name first (`remove_stale/1`), so a reader finds an entry
  whole or not at all, never partly removed. What a prune decided to
  remove is looked at again as it goes: one a lookup touched since is
  kept, and put back when the touch came between that look and the
  rename. No step reads an entry's state and then acts on its name
  assuming it still holds: a fetch is the touch itself (`fetch/1`), and
  an install is the rename. A reader that finds a fetched entry gone, or
  not holding what its manifest names, takes it for a miss, and one
  still there out of its name (`evict/1`).

  ## Turning it off

  `ARGUS_NO_CACHE=1` makes every store a no-op: nothing is read from one
  and nothing kept, and each run extracts and solves in scratch space as
  it would without `cache:`. It is the check that a result does not rest
  on something a key missed — after changing how a key is made, when an
  answer looks stale, and once before a release.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @typedoc "What `stale/2` spares; see there."
  @type prune_option ::
          {:keep, [String.t()]} | {:recent, non_neg_integer()} | {:max_age, pos_integer()}

  @subdirs ~w(shards solves programs bases ebins reads)

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

  @doc """
  One of the store's directories: `:shards`, `:solves`, `:programs`,
  `:bases`, `:ebins` or `:reads`.
  """
  @spec dir(Path.t(), :shards | :solves | :programs | :bases | :ebins | :reads) :: Path.t()
  def dir(root, kind) when kind in [:shards, :solves, :programs, :bases, :ebins, :reads],
    do: Path.join(root, Atom.to_string(kind))

  @doc """
  A kept entry: `{:ok, path}` (touched, so a pruner sees it in use) or
  `:miss`.

  The touch is the lookup: one change of the entry's times, which
  finds the entry or fails, and never makes one. Asking whether it
  exists and then touching it would let a prune take the entry in
  between, and a touch of a path that is not there writes an empty
  file at the entry's name: an answer no writer gave, read back and
  touched on every lookup after, so never pruned again. An entry that
  cannot be touched is a miss too: a pruner could not see it in use.
  """
  @spec fetch(Path.t()) :: {:ok, Path.t()} | :miss
  def fetch(entry) do
    now = System.os_time(:second)

    case :file.write_file_info(entry, file_info(mtime: now, atime: now), [{:time, :posix}]) do
      :ok -> {:ok, entry}
      {:error, _} -> :miss
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
  The entries of a store (its `shards/`, `solves/`, `programs/`, `bases/`,
  `ebins/` and `reads/`) that `prune/2` removes. Within each group (`<group>-<key>`, see the
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
        if Regex.match?(~r/^\d+-\d+(\.\d+\.\d+)?$/, name), do: :staging
      end)

    @subdirs
    |> Enum.flat_map(&stale_entries(Path.join(root, &1), opts, fn name, _type -> kind(name) end))
    |> Kernel.++(work)
    |> Enum.sort()
  end

  @doc """
  Removes `stale/2`, each by `remove_stale/1`; the paths it removed. An
  entry a lookup touched after `stale/2` looked at it stays.
  """
  @spec prune(Path.t(), [prune_option()]) :: [Path.t()]
  def prune(root, opts \\ []) do
    root |> stale(opts) |> Enum.filter(&remove_stale/1)
  end

  @doc """
  Removes one path `stale/2` named — an entry, a staging name or a
  run's scratch directory — unless it has been touched within the hour
  by now; whether it did.

  Whole: the path is renamed out of its name first, to a staging name
  beside it (which a crashed prune leaves to a later one), and removed
  from there, so a reader of the entry finds all of it or none of it.
  A lookup whose touch came between the look and the rename gets its
  entry back: the look is repeated on what was renamed, and an entry
  touched since returns to its name, unless a writer installed the key
  again meanwhile.
  """
  @spec remove_stale(Path.t()) :: boolean()
  def remove_stale(path) do
    with true <- untouched?(path),
         aside = "#{path}.#{:os.getpid()}.#{System.unique_integer([:positive])}",
         :ok <- File.rename(path, aside) do
      if untouched?(aside) do
        File.rm_rf(aside)
        true
      else
        put_back(aside, path)
        false
      end
    else
      _ -> false
    end
  end

  @doc """
  Takes an entry a reader found incomplete out of its name, whatever
  its age, as `remove_stale/1` takes one: renamed aside, then removed.
  The next lookup misses and writes it again, where an install would
  lose to what is there. A no-op when the entry is already gone.
  """
  @spec evict(Path.t()) :: :ok
  def evict(entry) do
    aside = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"
    with :ok <- File.rename(entry, aside), do: File.rm_rf(aside)
    :ok
  end

  # Untouched for the hour an entry is presumed in use. Renaming a path
  # within its directory leaves its modification time as it was.
  defp untouched?(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: touched}} -> System.os_time(:second) - touched > @live_seconds
      {:error, _} -> false
    end
  end

  # An entry a lookup touched as it was being removed, back under its
  # name. A writer that installed the key meanwhile keeps its own: a
  # directory is not renamed over one that is there, and a file is
  # linked back, which fails where one is.
  defp put_back(aside, path) do
    case File.lstat(aside) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:error, _} <- File.rename(aside, path), do: File.rm_rf(aside)

      {:ok, _file} ->
        _ = File.ln(aside, path)
        File.rm(aside)

      {:error, _} ->
        :ok
    end

    :ok
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
