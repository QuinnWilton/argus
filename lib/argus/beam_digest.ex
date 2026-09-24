defmodule Argus.BeamDigest do
  @moduledoc """
  A digest of a compiled module that names what it does, not where it
  was built.

  A beam's bytes carry the absolute path of the tree it was compiled in:
  the source file in its compile info and debug info, and — when the
  code reads `__DIR__`, `__ENV__.file` or `Application.app_dir/2` at
  compile time — in its literals too. Two worktrees at one commit build
  byte-different beams of the same code, so a cache keyed on the bytes
  misses in every worktree but the one that filled it. This digest reads
  the chunks instead, with the build root taken out.

  ## What is hashed

  Every chunk, in chunk-id order, except the ones that describe the
  code rather than being part of it:

    * `CInf` (compile options and the source path), `Docs` (prose) and
      `ExCk` (the Elixir type checker's export table) never are;
    * `Dbgi` and `Abst` (debug info) only with `debug_info: true`, for a
      caller whose consumer reads it — `Argus.Specs` reads an installed
      dependency's specs from its debug info.

  `Line` stays: an extraction that crashes records where
  (`Argus.Pipeline`), so the line table of the code a producer runs
  (`Argus.Cache.Code`) can reach a fact.
  A comment edit that moves no line leaves the digest alone; one that
  moves a line does not.

  ## What is normalized

  The build root is the directory holding the `_build` the beam lives
  under. Inside the literal table, the attributes and the debug info,
  every binary containing that root — and every charlist starting with
  it — is rewritten with the root replaced by `$ROOT`. Only that prefix
  moves: a path elsewhere on disk still keys the digest, so two trees
  can share a digest only when their code differs in nothing but where
  it sits. A beam outside any `_build` is hashed as it is.

  Two fields derived from the bytes above are cleared: a fun's
  `OldUniq` in `FunT`, and a `vsn` attribute (the default one is the
  module's MD5). Neither changes what the code computes.
  """

  @typedoc "Options: `debug_info:` (default `false`) also hashes `Dbgi` and `Abst`."
  @type option :: {:debug_info, boolean()}

  @never ~w(CInf Docs ExCk)
  @debug ~w(Dbgi Abst)
  @marker "$ROOT"

  @doc """
  The SHA-256 of `beam`'s normalized chunks, or the reason `:beam_lib`
  could not read them.
  """
  @spec digest(Path.t(), [option()]) :: {:ok, binary()} | {:error, term()}
  def digest(beam, opts \\ []) do
    debug_info? = Keyword.get(opts, :debug_info, false)
    root = build_root(beam)

    case :beam_lib.all_chunks(String.to_charlist(beam)) do
      {:ok, _module, chunks} ->
        hash =
          chunks
          |> Enum.map(fn {id, data} -> {List.to_string(id), data} end)
          |> Enum.reject(fn {id, _} -> id in @never or (id in @debug and not debug_info?) end)
          |> Enum.sort()
          |> Enum.reduce(:crypto.hash_init(:sha256), fn {id, data}, hash ->
            normalized = normalize(id, data, root)

            hash
            |> :crypto.hash_update(id)
            |> :crypto.hash_update(<<byte_size(normalized)::64>>)
            |> :crypto.hash_update(normalized)
          end)
          |> :crypto.hash_final()

        {:ok, hash}

      {:error, :beam_lib, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The directory holding the innermost `_build` on `beam`'s path, or
  `nil` when there is none.
  """
  @spec build_root(Path.t()) :: String.t() | nil
  def build_root(beam) do
    parts = beam |> Path.expand() |> Path.split()

    case parts |> Enum.with_index() |> Enum.filter(fn {p, _} -> p == "_build" end) do
      [] -> nil
      found -> parts |> Enum.take(found |> List.last() |> elem(1)) |> Path.join()
    end
  end

  # ── Chunks ──────────────────────────────────────────────────────────

  defp normalize(_id, data, nil = _root), do: data

  defp normalize("LitT", data, root), do: literals(data, root)
  defp normalize("Line", data, root), do: line_files(data, root)

  defp normalize("FunT", <<count::32, entries::binary>>, _root) do
    cleared =
      for <<name::32, arity::32, label::32, index::32, free::32, _old_uniq::32 <- entries>>,
        into: <<>>,
        do: <<name::32, arity::32, label::32, index::32, free::32, 0::32>>

    <<count::32, cleared::binary>>
  end

  defp normalize("Attr", data, root) do
    with {:ok, attributes} when is_list(attributes) <- decode(data) do
      attributes
      |> Enum.reject(&match?({:vsn, _}, &1))
      |> paths(root)
      |> :erlang.term_to_binary([:deterministic])
    else
      _undecodable -> data
    end
  end

  defp normalize(id, data, root) when id in @debug do
    case decode(data) do
      {:ok, term} -> term |> paths(root) |> :erlang.term_to_binary([:deterministic])
      :error -> data
    end
  end

  defp normalize(_id, data, _root), do: data

  # A stripped beam's `Abst` is empty; hashed as it is, like any chunk
  # that is not a term.
  defp decode(data) do
    {:ok, :erlang.binary_to_term(data)}
  rescue
    ArgumentError -> :error
  end

  # `<<UncompressedSize:32, Table>>`, the table zlib-compressed unless
  # the size is 0 (OTP 28 writes it uncompressed): `<<Count:32>>` then
  # each literal as `<<Size:32, ExternalTerm>>`.
  defp literals(<<size::32, table::binary>>, root) do
    <<count::32, entries::binary>> = if size == 0, do: table, else: :zlib.uncompress(table)

    normalized =
      for <<len::32, term::binary-size(len) <- entries>>, into: <<>> do
        encoded =
          term
          |> :erlang.binary_to_term()
          |> paths(root)
          |> :erlang.term_to_binary([:deterministic])

        <<byte_size(encoded)::32, encoded::binary>>
      end

    <<count::32, normalized::binary>>
  end

  # `<<Version:32, Flags:32, Instructions:32, Lines:32, Files:32>>`,
  # then `Lines` integer-tagged compact terms interleaved with the
  # atom-tagged ones that switch file, then the file names as
  # `<<Length:16, Name>>`. Mix compiles with names relative to the
  # project, so this is usually a no-op; a file compiled outside its
  # working directory is named in full.
  defp line_files(
         <<header::binary-size(12), lines::32, files::32, items::binary>> = data,
         root
       ) do
    table_at = byte_size(items) - byte_size(skip_line_items(items, lines))
    <<entries::binary-size(table_at), table::binary>> = items

    names = file_names(table, files, root, <<>>)
    <<header::binary, lines::32, files::32, entries::binary, names::binary>>
  rescue
    # A table this reader does not follow is hashed as written: at worst
    # a miss, never two different tables made equal.
    _malformed in [MatchError, FunctionClauseError, CaseClauseError, ArgumentError] -> data
  end

  defp line_files(data, _root), do: data

  # Exactly `count` names and nothing after them, or the match fails.
  defp file_names(<<>>, 0, _root, acc), do: acc

  defp file_names(<<len::16, name::binary-size(len), rest::binary>>, count, root, acc)
       when count > 0 do
    normalized = walk(name, root, [])

    file_names(
      rest,
      count - 1,
      root,
      <<acc::binary, byte_size(normalized)::16, normalized::binary>>
    )
  end

  defp skip_line_items(rest, 0), do: rest

  defp skip_line_items(items, n) do
    case CTF.decode(items) do
      {{:atom, _file}, rest} -> skip_line_items(rest, n)
      {_line, rest} -> skip_line_items(rest, n - 1)
    end
  end

  # ── Paths ───────────────────────────────────────────────────────────

  defp paths(term, root), do: walk(term, root, String.to_charlist(root))

  defp walk(bin, root, _chars) when is_binary(bin) do
    if :binary.match(bin, root) == :nomatch,
      do: bin,
      else: :binary.replace(bin, root, @marker, [:global])
  end

  defp walk([_ | _] = list, root, chars) do
    case strip_prefix(list, chars) do
      {:ok, rest} -> String.to_charlist(@marker) ++ walk(rest, root, chars)
      :error -> walk_list(list, root, chars)
    end
  end

  defp walk(tuple, root, chars) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&walk(&1, root, chars)) |> List.to_tuple()
  end

  defp walk(map, root, chars) when is_map(map) do
    # Through `:maps`, not `Enum`: a struct in a literal is a map with
    # no `Enumerable` implementation.
    :maps.fold(
      fn k, v, acc -> Map.put(acc, walk(k, root, chars), walk(v, root, chars)) end,
      %{},
      map
    )
  end

  defp walk(other, _root, _chars), do: other

  # Elements of a list, which may be improper.
  defp walk_list([head | tail], root, chars),
    do: [walk(head, root, chars) | walk_list(tail, root, chars)]

  defp walk_list([], _root, _chars), do: []
  defp walk_list(tail, root, chars), do: walk(tail, root, chars)

  defp strip_prefix(rest, []), do: {:ok, rest}
  defp strip_prefix([c | rest], [c | prefix]), do: strip_prefix(rest, prefix)
  defp strip_prefix(_list, _prefix), do: :error
end
