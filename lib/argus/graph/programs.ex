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
      `dl_tree` input, so any edit under it walks every program's
      includes again, and only a program that includes the edited file
      comes out different.
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
  alias Roux.Blob
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

  @doc """
  The tree a program is read from: argus's `priv/dl` for its own, the
  directory of a caller's file for a program of its own.
  """
  @spec tree(program()) :: Path.t()
  def tree({:custom, path}), do: path |> Path.expand() |> Path.dirname()
  def tree(_builtin), do: Catalog.priv_dl("") |> Path.expand()

  @doc """
  Each Datalog file under `root` and its content's digest: the
  `dl_tree` input a frontend sets for every tree a program is read from.
  """
  @spec tree_digests(Path.t()) :: %{String.t() => String.t()}
  def tree_digests(root) do
    root = Path.expand(root)

    for file <- Path.wildcard(Path.join(root, "**/*.dl")), into: %{} do
      {Path.relative_to(file, root), file |> File.read!() |> sha()}
    end
  end

  defquery :program_files, key: program do
    with {:ok, path} <- rules_path(program) do
      root = tree(program)
      _tree = Runtime.input(db, :dl_tree, root, default: nil)

      try do
        {:ok,
         for {spelled, file} <- Argus.Souffle.Program.program_files(path) do
           {spelled, Path.relative_to(file, root), file |> File.read!() |> sha()}
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
      Blob.cached(db.blob, {__MODULE__, :io, files, solver.version}, fn ->
        Argus.Souffle.ram_io(solver.bin, path)
      end)
    end
  end

  defquery :program_digest, key: program do
    with {:ok, _files} <- Runtime.query(db, :program_files, program),
         {:ok, io} <- Runtime.query(db, :program_io, program),
         {:ok, solver} <- solver(db),
         {:ok, path} <- rules_path(program) do
      relations = io.inputs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      try do
        declared = Argus.Souffle.Program.declared_digest(path, relations)
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
