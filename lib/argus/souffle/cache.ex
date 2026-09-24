defmodule Argus.Souffle.Cache do
  @moduledoc """
  Solve outputs kept on disk, so a solve whose inputs have not moved is
  read back instead of run again: `Argus.Souffle.run/3` consults it when
  given `solve_cache:`, and `Argus.Cache.Facts` for every solve of a run
  with `cache:` (the stage-0 call graph, the points-to stage, each
  analysis).

  A solve is keyed on everything that decides its outputs: the program
  with its transitive includes (`program_digest/1`), the solver's
  version, and the content of exactly the relation files the program
  reads, as Souffle resolves them (`Argus.Souffle.input_relations/2`).
  Nothing else in the facts directory takes part, so an edit that
  leaves a program's inputs byte-identical — a refactor of the
  extraction, a rule edit upstream whose stage came out the same —
  solves nothing again; and a stage's outputs feed the solves after it
  by their content, so a change that leaves stage 0's output unchanged
  re-solves nothing downstream.

  An entry is a directory of the solver's own output files, named
  `<program>-<key>` (or `<program>-<group>-<key>`, a group naming whose
  facts they were for retention's sake, `Argus.Cache.stale/2`), with a
  manifest of each output file's digest beside them (`manifest/1`): a
  stage's outputs are the next solve's inputs, keyed by those digests.
  It is written and installed as `Argus.Cache` describes: complete or
  absent, read-only, touched on every hit. Only a solve that succeeded
  is kept; a failure is reported every time.

  The outputs are the solver's, not their parse: a change to how argus
  reads them needs no invalidation.
  """

  @typedoc """
  A cache directory, or a directory and the group its entries are named
  under.
  """
  @type t :: Path.t() | {Path.t(), String.t()}

  @typedoc "Each relation file a solve reads, by name, and its content's digest."
  @type input_digests :: [{String.t(), String.t()}]

  # Moves every key: bump it when what an entry holds changes shape.
  @format "argus-solve-cache-2"

  # The digests of an entry's outputs, beside them.
  @manifest ".argus-digests"

  # How long `stamped/2` trusts its files without a look, and the size
  # below which it looks at their content, not only their stat.
  @restat_ms 1_000
  @content_stamp 1_000_000

  @doc """
  The entry a solve of `rules_path` over `facts_dir` would use under the
  options' `:solve_cache`: `{:ok, entry}`, nil when they name none (or
  stores are off, `Argus.Cache.enabled?/0`), or an error when the
  program's inputs cannot be resolved. Reads and digests each file the
  program reads.
  """
  @spec entry(Path.t(), String.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | nil | {:error, term()}
  def entry(rules_path, bin, facts_dir, opts) do
    with {dir, group} <- cache_option(opts),
         {:ok, inputs} <- Argus.Souffle.input_files(rules_path, souffle_bin: bin) do
      digests =
        Enum.map(inputs, fn file ->
          case Argus.Cache.file_digest(Path.join(facts_dir, file)) do
            {:ok, digest} -> {file, digest}
            {:error, _} -> {file, "absent"}
          end
        end)

      {:ok, named(dir, group, rules_path, bin, digests)}
    end
  end

  @doc """
  The entry a solve of `rules_path` would use under the options'
  `:solve_cache`, without the facts it reads: nil, since a kept solve
  is keyed on their content.
  """
  @deprecated "A kept solve is keyed on the files it reads; use entry/4"
  @spec entry(Path.t(), String.t(), keyword()) :: nil
  def entry(_rules_path, _bin, _opts), do: nil

  defp cache_option(opts) do
    case Keyword.get(opts, :solve_cache) do
      nil ->
        nil

      dir when is_binary(dir) ->
        if Argus.Cache.enabled?(), do: {dir, nil}, else: nil

      {dir, group} when is_binary(dir) and is_binary(group) ->
        if Argus.Cache.enabled?(), do: {dir, group}, else: nil

      other ->
        raise ArgumentError,
              ":solve_cache must be a directory or {directory, group}, got: #{inspect(other)}"
    end
  end

  @doc """
  The entry of a solve of `rules_path` under `dir`, given the digest of
  each file it reads: `<program>-<key>`, or `<program>-<group>-<key>`.
  """
  @spec named(Path.t(), String.t() | nil, Path.t(), String.t(), input_digests()) :: Path.t()
  def named(dir, group, rules_path, bin, digests) do
    key =
      Argus.Cache.key([
        @format,
        program_digest(rules_path),
        version(bin)
        | Enum.flat_map(Enum.sort(digests), fn {file, digest} -> [file, digest] end)
      ])

    name = program_name(rules_path)
    Path.join(dir, if(group, do: "#{name}-#{group}-#{key}", else: "#{name}-#{key}"))
  end

  @doc """
  Whether a solve of `rules_path` is kept in `cache`: always false now.
  A solve is keyed on the content of the files it reads, which a cache
  directory alone does not name.
  """
  @deprecated "A kept solve is keyed on the files it reads; solve with Argus.Souffle.run/3"
  @spec kept?(t() | {Path.t(), [binary()]}, Path.t(), String.t()) :: false
  def kept?(_cache, _rules_path, _bin), do: false

  @doc """
  Reads back a kept solve: `{:ok, entry}` (touched, so a pruner sees it
  in use) or `:miss`.
  """
  @spec fetch(Path.t()) :: {:ok, Path.t()} | :miss
  defdelegate fetch(entry), to: Argus.Cache

  @doc """
  A fresh staging directory for a solve that will be kept at `entry`.
  """
  @spec staging(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defdelegate staging(entry), to: Argus.Cache

  @doc """
  Installs a finished solve's staging directory as `entry`, with the
  manifest of its outputs' digests (`manifest/1`). Another solve that
  installed the same key first wins, and this copy is discarded; either
  way `entry` holds the outputs afterwards. Any other failure leaves
  `staging` in place for the caller.
  """
  @spec install(Path.t(), Path.t()) :: :ok | {:error, term()}
  def install(staging, entry) do
    with {:ok, digests} <- digest_outputs(staging),
         :ok <- File.write(Path.join(staging, @manifest), :erlang.term_to_binary(digests)) do
      Argus.Cache.install(staging, entry)
    end
  end

  defp digest_outputs(dir) do
    with {:ok, files} <- File.ls(dir) do
      Enum.reduce_while(Enum.sort(files), {:ok, %{}}, fn file, {:ok, acc} ->
        if String.starts_with?(file, ".") do
          {:cont, {:ok, acc}}
        else
          case Argus.Cache.file_digest(Path.join(dir, file)) do
            {:ok, digest} -> {:cont, {:ok, Map.put(acc, file, digest)}}
            {:error, reason} -> {:halt, {:error, {:digest_failed, file, reason}}}
          end
        end
      end)
    end
  end

  @doc """
  Each output file of a kept solve and its content's digest, from the
  manifest `install/2` wrote.
  """
  @spec manifest(Path.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def manifest(entry) do
    with {:ok, bytes} <- File.read(Path.join(entry, @manifest)) do
      {:ok, :erlang.binary_to_term(bytes, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :bad_manifest}
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
      files
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.reduce_while(:ok, fn file, :ok ->
        target = Path.join(output_dir, file)
        # A kept file is read-only, and a copy keeps its mode: the copy is
        # the caller's to write.
        with :ok <- File.cp(Path.join(entry, file), target),
             :ok <- File.chmod(target, 0o644) do
          {:cont, :ok}
        else
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

    if shipped?(path) do
      stamped({__MODULE__, :program_digest, path}, fn -> compute_program_digest(path) end)
    else
      path |> compute_program_digest() |> elem(1)
    end
  end

  # A program argus ships is read at most once a second (`stamped/2`):
  # every solve of every corpus checkout asks. One anywhere else — a
  # test's, a caller's own — is read on every call, so an edit is seen
  # at once.
  defp shipped?(path) do
    case :code.priv_dir(:panoptes) do
      dir when is_list(dir) ->
        String.starts_with?(path, Path.join(List.to_string(dir), "dl") <> "/")

      _ ->
        false
    end
  end

  defp compute_program_digest(path) do
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
        ~r/^\s*[.#]include\s+"([^"]+)"/m
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

  @doc false
  # The name a program's entries start with.
  @spec program_name(Path.t()) :: String.t()
  def program_name(rules_path), do: Path.basename(rules_path, ".dl")
end
