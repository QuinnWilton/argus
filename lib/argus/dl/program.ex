defmodule Argus.Dl.Program do
  @moduledoc """
  A Datalog program as a solve reads it: its files (the program and
  every file it `.include`s, transitively, resolved as FlowLog resolves
  an include, relative to the including file), and digests of them
  that name what decides a solve's outputs.

  `declared_digest/2` counts a file of declarations alone (argus's
  generated `base.dl`, `layer2.dl`, `priors.dl`) only by the
  declarations of the relations the program loads: FlowLog prunes an
  input no rule that reaches an output reads before it plans anything,
  so a relation added to the schema, or another relation's prose,
  moves no program's digest, and builds no engine again. The query graph
  keys each program on it (`Argus.Graph.Programs`, `Argus.FlowLog.program_digest/2`).
  """

  # How long `stamped/2` trusts its files without a look, and the size
  # below which it looks at their content, not only their stat.
  @restat_ms 1_000
  @content_stamp 1_000_000

  @doc """
  A digest of a Datalog program: its own source and every file it
  includes, transitively, resolved the way FlowLog resolves an include
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
  defp shipped?(path), do: String.starts_with?(path, Argus.Dl.shipped() <> "/")

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

  FlowLog prunes an input relation no rule that reaches an output
  reads, before it plans anything: a declaration it prunes decides
  nothing a solve writes, and no line of the engine built for it. A
  declaration that no longer compiles beside the rest (a pruned rule
  that joins a relation whose type changed, a name that is now declared
  twice) fails the program, and that is caught before a solve is keyed:
  the relations it loads are resolved again (`Argus.FlowLog.manifest/2`)
  under `relations = :all`, which every declaration moves. `Argus.Graph.Identity.DeclaredDigestTest`
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
          :error -> {:text, spelled, :crypto.hash(:sha256, uncommented(content))}
        end
      end)

    {Enum.map(files, &elem(&1, 1)), parts}
  end

  @doc ~S"""
  A program file's text as a solve reads it: without the lines that are
  a line comment alone (after any indentation), and without blank lines
  — what an edit to a rule's prose touches. FlowLog skips every such
  line, so a solve of the file writes what a solve of its text as given
  writes.

  A file holding a backslash at the end of a line, or the trigraph for
  one, is kept as given: it is not a program FlowLog reads differently,
  but a key over it may as well be conservative. A comment line that
  opens or closes a block comment is kept.

      iex> Argus.Dl.Program.uncommented("a(1).\n// why\n\n  // indented\nb(2).\n")
      "a(1).\nb(2)."

      iex> Argus.Dl.Program.uncommented("a(1). \\\n// spliced\nb(2).")
      "a(1). \\\n// spliced\nb(2)."
  """
  @spec uncommented(String.t()) :: String.t()
  def uncommented(content) do
    if String.contains?(content, ["\\\n", "\\\r", "??/"]) do
      content
    else
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or dropped_comment?(&1)))
      |> Enum.join("\n")
    end
  end

  defp dropped_comment?(line) do
    case String.trim_leading(line) do
      "//" <> comment -> not String.contains?(comment, ["/*", "*/"])
      _code -> false
    end
  end

  @doc """
  The declarations of a file that holds nothing else, as
  `mix argus.gen.dl` writes one: `{:ok, [{relation, lines}]}`, each
  relation's `.decl` and `.input` lines in order, or `:error` for any
  other file.

  A line is blank, a line comment, `.decl name(field: type, ...)` or
  `.input name` right after its own `.decl` — and nothing else, not an
  attribute or another comment: anything this does not read is text a
  key holds whole. The `mutable` qualifier `mix argus.gen.dl` gives every
  fact relation is part of its declaration's line. A comment ending in a
  backslash (or the trigraph for one) is not read as a comment either.
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
      match =
          Regex.run(~r/^\.decl ([A-Za-z_][A-Za-z0-9_]*)\([A-Za-z0-9_:, ]*\)( mutable)?$/, line) ->
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
end
