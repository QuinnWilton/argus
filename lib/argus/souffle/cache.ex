defmodule Argus.Souffle.Cache do
  @moduledoc """
  Solve outputs kept on disk, so a solve whose inputs have not moved is
  read back instead of run again: `Argus.Souffle.run/3` consults it when
  given `solve_cache:`, and `Argus.Cache.Facts` for every solve of a run
  with `cache:` (the stage-0 call graph, the points-to stage, each
  analysis).

  A solve is keyed on everything that decides its outputs: the program
  with its transitive includes as the solve reads them
  (`declared_digest/2`: of the generated declaration files, only the
  declarations of the relations it loads), the solver's version, and
  the content of exactly the relation files the program reads, as
  Souffle resolves them (`Argus.Souffle.input_relations/2`). A schema
  edit that adds a relation, or changes one a program does not load,
  re-solves nothing.
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

  # Moves every key: bump it when what an entry holds, or how a key is
  # made, changes.
  @format "argus-solve-cache-3"

  # The digests of an entry's outputs, beside them.
  @manifest ".argus-digests"

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
         {:ok, inputs} <- Argus.Souffle.input_files(rules_path, souffle_bin: bin),
         {:ok, relations} <- Argus.Souffle.input_relations(rules_path, souffle_bin: bin) do
      digests =
        Enum.map(inputs, fn file ->
          case Argus.Cache.file_digest(Path.join(facts_dir, file)) do
            {:ok, digest} -> {file, digest}
            {:error, _} -> {file, "absent"}
          end
        end)

      {:ok, named(dir, group, rules_path, bin, digests, relations)}
    end
  end

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
  each file it reads and the relations it loads
  (`Argus.Souffle.input_relations/2`; `:all` counts every declaration):
  `<program>-<key>`, or `<program>-<group>-<key>`.
  """
  @spec named(
          Path.t(),
          String.t() | nil,
          Path.t(),
          String.t(),
          input_digests(),
          [String.t()] | :all
        ) :: Path.t()
  def named(dir, group, rules_path, bin, digests, relations) do
    key =
      Argus.Cache.key([
        @format,
        declared_digest(rules_path, relations),
        version(bin)
        | Enum.flat_map(Enum.sort(digests), fn {file, digest} -> [file, digest] end)
      ])

    name = program_name(rules_path)
    Path.join(dir, if(group, do: "#{name}-#{group}-#{key}", else: "#{name}-#{key}"))
  end

  @doc """
  `named/6`, with the relations the program loads resolved here — or,
  when they cannot be, every declaration counted.
  """
  @deprecated "Use named/6 with the relations the program loads (Argus.Souffle.input_relations/2)"
  @spec named(Path.t(), String.t() | nil, Path.t(), String.t(), input_digests()) :: Path.t()
  def named(dir, group, rules_path, bin, digests) do
    relations =
      case Argus.Souffle.input_relations(rules_path, souffle_bin: bin) do
        {:ok, relations} -> relations
        {:error, _} -> :all
      end

    named(dir, group, rules_path, bin, digests, relations)
  end

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
      Argus.Cache.install(staging, entry, [@manifest | Map.keys(digests)])
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

  @doc "A digest of a program's files: `Argus.Souffle.Program.program_digest/1`."
  @spec program_digest(Path.t()) :: binary()
  defdelegate program_digest(rules_path), to: Argus.Souffle.Program

  @doc """
  A program's digest as a solve loading `relations` reads it:
  `Argus.Souffle.Program.declared_digest/2`.
  """
  @spec declared_digest(Path.t(), [String.t()] | :all) :: binary()
  defdelegate declared_digest(rules_path, relations), to: Argus.Souffle.Program

  @doc "A file of declarations alone: `Argus.Souffle.Program.declarations/1`."
  @spec declarations(String.t()) :: {:ok, [{String.t(), String.t()}]} | :error
  defdelegate declarations(content), to: Argus.Souffle.Program

  @doc "A value kept while its files hold: `Argus.Souffle.Program.stamped/2`."
  @spec stamped(term(), (-> {[Path.t()], value})) :: value when value: term()
  defdelegate stamped(key, compute), to: Argus.Souffle.Program

  @doc "A program's files: `Argus.Souffle.Program.program_files/1`."
  @spec program_files(Path.t()) :: [{String.t(), Path.t()}]
  defdelegate program_files(rules_path), to: Argus.Souffle.Program

  @doc """
  The solver's `--version` output, once per VM for each binary (asked
  again when the binary is replaced, `stamped/2`): the part of a key
  that names the solver wherever it is installed.
  """
  @spec version(String.t()) :: String.t()
  def version(bin) do
    stamped({__MODULE__, :version, bin}, fn ->
      {version, _exit} = ask_version(bin)
      {[bin], version}
    end)
  end

  @doc """
  `version/1`, kept across VMs in `dir` — a store's `programs/`
  (`Argus.Cache`), or nil for none — so a fresh VM starts no solver to
  ask: under a stamp of the binary, its path and the modification time,
  size and inode of the file it runs. It is the same answer
  `version/1` gives in the VM after it.

  A stamp names a file, not what the file runs. A script (`#!`), such as
  a version manager's shim, can run another solver without moving, so
  its version is asked in every VM, as without `dir`; so is a binary
  written within the last two seconds, which a stamp cannot tell from a
  second write within the same second, and an answer the solver gave
  without exiting cleanly.
  """
  @spec version(String.t(), Path.t() | nil) :: String.t()
  def version(bin, nil), do: version(bin)

  def version(bin, dir) when is_binary(dir) do
    stamped({__MODULE__, :version, bin}, fn -> {[bin], kept_version(bin, dir)} end)
  end

  # Moves every kept version: bump it when what an entry holds changes.
  # An entry's first line is this, then the answer: a solver may answer
  # nothing, so an empty or foreign file at the entry's name is no
  # answer, and is written again.
  @version_format "argus-solver-version-2"
  @racy_seconds 2

  defp kept_version(bin, dir) do
    case solver_stamp(bin) do
      {:ok, stamp} ->
        entry = Path.join(dir, "souffle-" <> Argus.Cache.key([@version_format, bin | stamp]))

        with {:ok, entry} <- Argus.Cache.fetch(entry),
             {:ok, @version_format <> "\n" <> version} <- File.read(entry) do
          version
        else
          _missing ->
            case ask_version(bin) do
              {version, :clean} ->
                keep_version(entry, version)
                version

              {version, :unclean} ->
                version
            end
        end

      :unstamped ->
        {version, _exit} = ask_version(bin)
        version
    end
  end

  # The stat of the file `bin` runs (a symbolic link followed), unless
  # the stamp cannot vouch for what it runs.
  defp solver_stamp(bin) do
    with {:ok, %File.Stat{type: :regular, mtime: mtime, size: size, inode: inode}} <-
           File.stat(bin, time: :posix),
         true <- mtime < System.os_time(:second) - @racy_seconds,
         false <- script?(bin) do
      {:ok, Enum.map([mtime, size, inode], &Integer.to_string/1)}
    else
      _ -> :unstamped
    end
  end

  defp script?(bin) do
    case File.open(bin, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, "#!"} -> true
      {:ok, _} -> false
      {:error, _} -> true
    end
  end

  # A store that cannot be written to is asked around, not failed on.
  defp keep_version(entry, version) do
    staging = "#{entry}.#{:os.getpid()}.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(entry)),
         :ok <- File.write(staging, [@version_format, "\n", version]),
         :ok <- Argus.Cache.install(staging, entry) do
      :ok
    else
      _ -> File.rm(staging)
    end
  end

  # `{output, :clean | :unclean}`: what the solver printed, and whether
  # it exited cleanly — only a clean answer is kept across VMs.
  defp ask_version(bin) do
    case System.cmd(bin, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> {out, :clean}
      {out, _status} -> {out, :unclean}
    end
  rescue
    _ -> {"unrunnable", :unclean}
  end

  @doc false
  # The name a program's entries start with.
  @spec program_name(Path.t()) :: String.t()
  def program_name(rules_path), do: Path.basename(rules_path, ".dl")
end
