defmodule Argus.Graph.Programs do
  @moduledoc """
  The Datalog programs the graph solves, as a solve reads them.

  A program is the call graph's (`:stage0`), the points-to stage's two
  (`:points_to`, and `:points_to_bounded`, which it runs in place of the
  exact one when that outgrows its budget), a built-in analysis's (its
  name), or a program of a caller's own (`{:custom, path}`).

    * `program_files(program)` — the program's files, each by the name
      it is included by, its path under its tree and its content's
      digest (`Argus.Souffle.Program.program_files/1`): reads the tree's
      `dl_tree` input (`tree/1`), so any edit under it walks every
      program's includes again, and only a program that includes the
      edited file comes out different.
    * `program_io(program)` — what the program reads and writes, as
      Souffle resolves them (`Argus.Souffle.ram_io/2`), kept in the blob
      store's action cache by the program's files and the solver's
      version: a warm run starts no solver to ask.
    * `program_digest(program)` — the program as a solve of it loads it
      (`Argus.Souffle.Program.declared_digest/2`: of a generated file of
      declarations, only the relations it loads) with the solver's
      version: what every solve of it is keyed on.

  Each is `{:ok, value}` or `{:error, reason}`: a program whose file is
  missing, or that the solver rejects, fails every solve that reads it
  with the reason.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Analysis.Catalog
  alias Argus.Souffle.Program
  alias Roux.Runtime

  @typedoc "A program the graph solves."
  @type program :: :stage0 | :points_to | :points_to_bounded | atom() | {:custom, Path.t()}

  @doc "The file a program's solve runs, or an error for an unknown analysis."
  @spec rules_path(program()) :: {:ok, Path.t()} | {:error, term()}
  def rules_path(:stage0), do: {:ok, Argus.Analysis.stage0_rules_path()}
  def rules_path(:points_to), do: {:ok, Argus.Analysis.points_to_rules_path()}
  def rules_path(:points_to_bounded), do: {:ok, Argus.Analysis.points_to_bounded_rules_path()}
  def rules_path({:custom, path}), do: {:ok, Path.expand(path)}
  def rules_path(analysis) when is_atom(analysis), do: Catalog.rules_path(analysis)

  @typedoc """
  What a program is read from, as the `dl_tree` input is keyed: the
  directory of argus's own programs, or a caller's program file.
  """
  @type tree :: Path.t() | {:program, Path.t()}

  @doc """
  What a program is read from (`t:tree/0`): argus's `priv/dl` for its
  own, and for a program of a caller's own, that program — its file and
  every file it includes, never the directory it sits in, which may be
  anywhere (a home directory, the system's temporary one).
  """
  @spec tree(program()) :: tree()
  def tree({:custom, path}), do: {:program, Path.expand(path)}
  def tree(_builtin), do: Catalog.priv_dl("") |> Path.expand()

  @doc """
  The `dl_tree` input for a tree: each Datalog file under argus's
  directory, or each file a caller's program includes (itself among
  them), by its path relative to the directory and its content's
  digest. A caller's file that cannot be read is named with the reason.
  """
  @spec tree_digests(tree()) :: %{String.t() => String.t() | {:unreadable, term()}}
  def tree_digests({:program, path}) do
    Map.new(Program.program_files(path), fn {_spelled, file} ->
      case File.read(file) do
        {:ok, bytes} -> {file, sha(bytes)}
        {:error, reason} -> {file, {:unreadable, reason}}
      end
    end)
  rescue
    error in File.Error -> %{error.path => {:unreadable, error.reason}}
  end

  def tree_digests(root) do
    root = Path.expand(root)

    # Each file's digest kept in the VM while its stamp holds: a session
    # per API call reads argus's hundred programs' stamps, not their text.
    for file <- Path.wildcard(Path.join(root, "**/*.dl")), into: %{} do
      digest = Roux.Stamp.memo({__MODULE__, :sha, file}, [file], fn -> sha(File.read!(file)) end)
      {Path.relative_to(file, root), digest}
    end
  end

  # A program's includes, walked once for each content of its tree
  # (every file's digest, the `dl_tree` input), and kept in the VM and
  # the store: an edit anywhere in the tree walks it again. Without the
  # input, walked every time.
  defp walk(_db, path, nil), do: Program.program_files(path)

  defp walk(db, path, digests) do
    key = {__MODULE__, :walk, path, sha(:erlang.term_to_binary(digests, [:deterministic]))}
    Roux.Stamp.memo(key, [], fn -> Program.program_files(path) end, store: db.blob)
  end

  # A file's digest as the tree's input holds it, or read.
  defp digest(tree, root, digests, file) do
    key = if match?({:program, _}, tree), do: file, else: Path.relative_to(file, root)

    case digests && Map.get(digests, key) do
      digest when is_binary(digest) -> digest
      _ -> file |> File.read!() |> sha()
    end
  end

  # The directory a program's files are named relative to.
  defp dir({:program, path}), do: Path.dirname(path)
  defp dir(root), do: root

  defquery :program_files, key: program do
    # Which file an analysis's program is: its module's to say.
    if is_atom(program) and program not in [:stage0, :points_to, :points_to_bounded],
      do: _ = Runtime.query(db, :analysis_code, program)

    with {:ok, path} <- rules_path(program) do
      tree = tree(program)
      digests = Runtime.input(db, :dl_tree, tree, default: nil)
      root = dir(tree)

      try do
        {:ok,
         for {spelled, file} <- walk(db, path, digests) do
           {spelled, Path.relative_to(file, root), digest(tree, root, digests, file)}
         end}
      rescue
        error in File.Error -> {:error, {:unreadable, Path.relative_to(error.path, root)}}
      end
    end
  end

  defquery :program_io, key: program do
    with {:ok, files} <- Runtime.query(db, :program_files, program),
         {:ok, solver} <- solver(db),
         {:ok, path} <- rules_path(program) do
      # Kept in the VM, and in the store for a fresh one.
      Roux.Stamp.memo(
        {__MODULE__, :io, files, solver.version},
        [],
        fn ->
          Argus.Souffle.ram_io(solver.bin, path)
        end,
        store: db.blob
      )
    end
  end

  defquery :program_digest, key: program do
    with {:ok, files} <- Runtime.query(db, :program_files, program),
         {:ok, io} <- Runtime.query(db, :program_io, program),
         {:ok, solver} <- solver(db),
         {:ok, path} <- rules_path(program) do
      relations = io.inputs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      try do
        # The files by their digests: a program read once per VM.
        declared =
          Roux.Stamp.memo(
            {__MODULE__, :declared, files, relations},
            [],
            fn -> Program.declared_digest(path, relations) end,
            store: db.blob
          )

        {:ok, sha(:erlang.term_to_binary({declared, solver.version}, [:deterministic]))}
      rescue
        # A file of the program went missing since its files were read.
        error in File.Error -> {:error, {:unreadable, error.path}}
      end
    end
  end

  @doc "The solver the graph's `solver` input names, or `{:error, :souffle_not_found}`."
  @spec solver(Roux.Database.t()) ::
          {:ok, %{bin: String.t(), version: String.t(), timeout: timeout()}} | {:error, term()}
  def solver(db) do
    case Runtime.input(db, :solver, :all, default: nil) do
      %{bin: _, version: _} = solver -> {:ok, solver}
      nil -> {:error, :souffle_not_found}
    end
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
