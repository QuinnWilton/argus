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
  A digest of a Datalog program as a solve loading `relations` reads it
  (`:all`: as any solve of it does): its own source and every file it
  includes, transitively, as `program_digest/1` names them — except
  that a file of declarations alone, as `mix argus.gen.dl` writes them
  (`declarations/1`), counts only by the declarations of `relations`,
  in order, and not by its comments.

  Souffle prunes an input relation no rule that reaches an output
  reads, before it loads anything: a declaration it prunes decides
  nothing a solve writes. A declaration that no longer compiles beside
  the rest — a pruned rule that joins a relation whose type changed, a
  name that is now declared twice — fails the program, and that is
  caught before a solve is keyed: the relations it loads are resolved
  again (`Argus.Souffle.input_relations/2`) under `relations = :all`,
  which every declaration moves. `Argus.Souffle.DeclaredDigestTest`
  changes every declaration a shipped program does not load and
  checks that its outputs, byte for byte, and this digest do not move.
  """
  @spec declared_digest(Path.t(), [String.t()] | :all) :: binary()
  def declared_digest(rules_path, relations) do
    path = Path.expand(rules_path)

    parts =
      if shipped?(path) do
        stamped({__MODULE__, :program_parts, path}, fn -> program_parts(path) end)
      else
        path |> program_parts() |> elem(1)
      end

    keep = if relations == :all, do: :all, else: MapSet.new(relations)

    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), fn
      {:text, spelled, digest}, hash ->
        hash_parts(hash, ["text", spelled, digest])

      {:declarations, spelled, blocks}, hash ->
        kept =
          for {relation, block} <- blocks,
              keep == :all or MapSet.member?(keep, relation),
              part <- [relation, block],
              do: part

        hash_parts(hash, ["declarations", spelled, Integer.to_string(length(kept)) | kept])
    end)
    |> :crypto.hash_final()
  end

  defp hash_parts(hash, parts) do
    Enum.reduce(parts, hash, fn part, hash ->
      :crypto.hash_update(hash, <<byte_size(part)::64>> <> part)
    end)
  end

  # Each file of the program, in `program_files/1`'s order: a file of
  # declarations alone as its declarations, any other by its content.
  defp program_parts(path) do
    files = program_files(path)

    parts =
      Enum.map(files, fn {spelled, file} ->
        content = File.read!(file)

        case declarations(content) do
          {:ok, blocks} -> {:declarations, spelled, blocks}
          :error -> {:text, spelled, :crypto.hash(:sha256, content)}
        end
      end)

    {Enum.map(files, &elem(&1, 1)), parts}
  end

  @doc """
  The declarations of a file that holds nothing else, as
  `mix argus.gen.dl` writes one: `{:ok, [{relation, lines}]}`, each
  relation's `.decl` and `.input` lines in order, or `:error` for any
  other file.

  A line is blank, a line comment, `.decl name(field: type, ...)` or
  `.input name` right after its own `.decl` — and nothing else, not a
  qualifier, an attribute or another comment: anything this does not
  read is text a key holds whole. A comment ending in a backslash (or
  the trigraph for one) splices the next line into it in Souffle's
  preprocessor, so it is not read as a comment.
  """
  @spec declarations(String.t()) :: {:ok, [{String.t(), String.t()}]} | :error
  def declarations(content) do
    content
    |> String.split("\n")
    |> Enum.reduce_while({[], nil}, fn line, {blocks, pending} ->
      case {declaration_line(line), pending} do
        {:blank, pending} ->
          {:cont, {blocks, pending}}

        {{:decl, relation}, nil} ->
          {:cont, {blocks, {relation, line}}}

        {{:input, relation}, {relation, decl}} ->
          {:cont, {[{relation, decl <> "\n" <> line} | blocks], nil}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {blocks, nil} -> {:ok, Enum.reverse(blocks)}
      _ -> :error
    end
  end

  defp declaration_line(""), do: :blank

  defp declaration_line("//" <> comment) do
    if String.ends_with?(comment, "\\") or String.contains?(comment, "??/"),
      do: :other,
      else: :blank
  end

  defp declaration_line(line) do
    cond do
      match = Regex.run(~r/^\.decl ([A-Za-z_][A-Za-z0-9_]*)\([A-Za-z0-9_:, ]*\)$/, line) ->
        {:decl, Enum.at(match, 1)}

      match = Regex.run(~r/^\.input ([A-Za-z_][A-Za-z0-9_]*)$/, line) ->
        {:input, Enum.at(match, 1)}

      true ->
        :other
    end
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
  @version_format "argus-solver-version-1"
  @racy_seconds 2

  defp kept_version(bin, dir) do
    case solver_stamp(bin) do
      {:ok, stamp} ->
        entry = Path.join(dir, "souffle-" <> Argus.Cache.key([@version_format, bin | stamp]))

        with {:ok, entry} <- Argus.Cache.fetch(entry),
             {:ok, version} <- File.read(entry) do
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
         :ok <- File.write(staging, version),
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
