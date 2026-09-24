defmodule Argus.Souffle.Cache do
  @moduledoc """
  Solve outputs kept on disk, so a solve whose program and solver have
  not moved is read back instead of run again: `Argus.Souffle.run/3`
  consults it when given `solve_cache:`.

  The caller keeps one cache directory per content of the facts it
  solves over, so the facts are named by the directory and never read:
  `Argus.Corpus` keeps it inside the facts cache entry the solves read.
  A solve is keyed on its program (`program_digest/1`, its transitive
  includes with it), the solver's version, and a salt the caller folds
  in for what was derived into the facts directory after the entry was
  made (the points-to stage an analysis reads,
  `Argus.Analysis.Extraction.solve_cache/2`).

  An entry is a directory of the solver's own output files, named
  `<program>-<key>`, written into a staging directory beside it and
  renamed into place: complete or absent, never half-written. A second
  solve of the same key racing the first loses the rename and discards
  its copy. A hit touches its entry, which is what a pruner reads to tell
  an entry in use from one nobody will read again (`Argus.Corpus`). Only
  a solve that succeeded is kept; a failure is reported every time.

  The outputs are the solver's, not their parse: a change to how argus
  reads them needs no invalidation.
  """

  @typedoc """
  A cache directory, and the salt folded into each key: binaries naming
  what the facts directory holds beyond the content the directory stands
  for.
  """
  @type t :: {Path.t(), [binary()]}

  # Moves every key: bump it when what an entry holds changes shape.
  @format "argus-solve-cache-1"

  # How long `stamped/2` trusts its files without a look, and the size
  # below which it looks at their content, not only their stat.
  @restat_ms 1_000
  @content_stamp 1_000_000

  @doc """
  The entry directory a solve of `rules_path` would use under the
  options' `:solve_cache`, or nil when they name none.
  """
  @spec entry(Path.t(), String.t(), keyword()) :: Path.t() | nil
  def entry(rules_path, bin, opts) do
    case Keyword.get(opts, :solve_cache) do
      nil -> nil
      dir when is_binary(dir) -> keyed_entry(dir, [], rules_path, bin)
      {dir, salt} when is_binary(dir) and is_list(salt) -> keyed_entry(dir, salt, rules_path, bin)
    end
  end

  defp keyed_entry(dir, salt, rules_path, bin) do
    key = digest([@format, program_digest(rules_path), version(bin) | salt])
    Path.join(dir, "#{program_name(rules_path)}-#{key}")
  end

  @doc """
  Whether a solve of `rules_path` is kept in `cache` (touching it, as a
  hit does): a caller that finds every solve it needs kept may skip
  preparing the facts they would read.
  """
  @spec kept?(t(), Path.t(), String.t()) :: boolean()
  def kept?({dir, salt}, rules_path, bin) do
    match?({:ok, _}, fetch(keyed_entry(dir, salt, rules_path, bin)))
  end

  @doc """
  Reads back a kept solve: `{:ok, entry}` (touched, so a pruner sees it
  in use) or `:miss`.
  """
  @spec fetch(Path.t()) :: {:ok, Path.t()} | :miss
  def fetch(entry) do
    if File.dir?(entry) do
      File.touch(entry)
      {:ok, entry}
    else
      :miss
    end
  end

  @doc """
  A fresh staging directory for a solve that will be kept at `entry`.
  """
  @spec staging(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def staging(entry) do
    staging = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    case File.mkdir_p(staging) do
      :ok -> {:ok, staging}
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  @doc """
  Installs a finished solve's staging directory as `entry`. Another
  solve that installed the same key first wins, and this copy is
  discarded; either way `entry` holds the outputs afterwards. Any other
  failure leaves `staging` in place for the caller.
  """
  @spec install(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  def install(staging, entry) do
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

  @doc """
  Copies an entry's output files into `output_dir`, replacing what is
  there, as the solver writing into it would. Copies, not links: the
  caller owns `output_dir`, and a later solve writing into it in place
  must not reach the entry.
  """
  @spec place(Path.t(), Path.t()) :: :ok | {:error, term()}
  def place(entry, output_dir) do
    with {:ok, files} <- File.ls(entry),
         :ok <- File.mkdir_p(output_dir) do
      Enum.reduce_while(files, :ok, fn file, :ok ->
        case File.cp(Path.join(entry, file), Path.join(output_dir, file)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:copy_failed, file, reason}}}
        end
      end)
    end
  end

  @doc """
  A digest of a Datalog program: its own source and every file it
  includes, transitively, resolved the way Souffle resolves an include
  (relative to the including file). Each file is named as the program
  spells it, so the digest is the same wherever the tree is checked out.
  """
  @spec program_digest(Path.t()) :: binary()
  def program_digest(rules_path) do
    path = Path.expand(rules_path)

    stamped({__MODULE__, :program_digest, path}, fn ->
      files = program_files(path)

      digest =
        Enum.reduce(files, :crypto.hash_init(:sha256), fn {spelled, file}, hash ->
          content = File.read!(file)

          hash
          |> :crypto.hash_update(<<byte_size(spelled)::32>> <> spelled)
          |> :crypto.hash_update(<<byte_size(content)::64>> <> content)
        end)
        |> :crypto.hash_final()

      {Enum.map(files, &elem(&1, 1)), digest}
    end)
  end

  @doc """
  `compute`'s value, kept for the life of the VM under `key` while the
  files it was computed from are unchanged. `compute` returns the files
  it read and the value; a later call looks at those files again at
  most once a second (their stat, and a small one's content) and
  computes afresh when one moved. Reading and hashing a program's
  sources on every solve was most of a warm corpus run's system time,
  and a stat per file per call still cost a millisecond a file on a
  busy disk.
  """
  @spec stamped(term(), (-> {[Path.t()], value})) :: value when value: term()
  def stamped(key, compute) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {files, stamps, value, checked} ->
        cond do
          now - :atomics.get(checked, 1) < @restat_ms ->
            value

          stamps(files) == stamps ->
            :atomics.put(checked, 1, now)
            value

          true ->
            restamp(key, compute, now)
        end

      nil ->
        restamp(key, compute, now)
    end
  end

  defp restamp(key, compute, now) do
    {files, value} = compute.()
    checked = :atomics.new(1, signed: true)
    :atomics.put(checked, 1, now)
    :persistent_term.put(key, {files, stamps(files), value, checked})
    value
  end

  # A small file (a Datalog source) by its content as well: a
  # modification time has a second's resolution, and an edit that keeps
  # the size inside that second is still an edit. A large one (the
  # solver) is replaced, not edited, which moves its inode or size.
  defp stamps(files) do
    Enum.map(files, fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} when size <= @content_stamp ->
          {mtime, size, inode, content_stamp(file)}

        {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} ->
          {mtime, size, inode}

        {:error, reason} ->
          reason
      end
    end)
  end

  defp content_stamp(file) do
    case File.read(file) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, reason} -> reason
    end
  end

  @doc """
  The files of a Datalog program, `{spelling, path}` in the order they
  are first met: the program itself (spelled by its basename), then each
  `.include`d file (spelled as the include writes it), depth first.
  """
  @spec program_files(Path.t()) :: [{String.t(), Path.t()}]
  def program_files(rules_path) do
    walk([{Path.basename(rules_path), Path.expand(rules_path)}], %{}, [])
  end

  defp walk([], _seen, acc), do: Enum.reverse(acc)

  defp walk([{spelled, path} | rest], seen, acc) do
    if Map.has_key?(seen, path) do
      walk(rest, seen, acc)
    else
      included =
        ~r/^\s*\.include\s+"([^"]+)"/m
        |> Regex.scan(File.read!(path))
        |> Enum.map(fn [_, rel] -> {rel, Path.expand(rel, Path.dirname(path))} end)

      walk(included ++ rest, Map.put(seen, path, true), [{spelled, path} | acc])
    end
  end

  @doc """
  The solver's `--version` output, once per VM for each binary (asked
  again when the binary is replaced, `stamped/2`): the part of a key
  that names the solver wherever it is installed.
  """
  @spec version(String.t()) :: String.t()
  def version(bin) do
    stamped({__MODULE__, :version, bin}, fn ->
      version =
        try do
          {out, _status} = System.cmd(bin, ["--version"], stderr_to_stdout: true)
          out
        rescue
          _ -> "unrunnable"
        end

      {[bin], version}
    end)
  end

  defp program_name(rules_path), do: Path.basename(rules_path, ".dl")

  defp digest(parts) do
    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), fn part, hash ->
      :crypto.hash_update(hash, <<byte_size(part)::64>> <> part)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
