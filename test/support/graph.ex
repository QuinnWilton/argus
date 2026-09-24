defmodule Scry.Test.Graph do
  @moduledoc """
  Drives `Scry.Analysis` directly over a roux database, without Mix: the
  harness for the incremental≡batch parity gate and for tests that need
  to reach into the graph (a failing solver, a moved rule digest).

  The parity fixture under `test/fixtures/parity` is a copy of argus's
  own fixtures for the relations the whole-program analyses lean on —
  process points-to (`PidFlow`), unreceived messages, check-then-act
  over registries, ETS and Mnesia, the PADL 2010 Erlang race programs —
  plus one per remaining concern, so every analysis in `:all` has rows
  to agree on. Copied verbatim from argus's `test/fixtures` (and
  `test/fixtures/erl`) at 86137a0; refresh them from there when argus
  grows a relation worth gating.
  """

  import ExUnit.CaptureIO, only: [capture_io: 2]

  alias Roux.{Database, GC, Input}

  @parity Path.expand("../fixtures/parity", __DIR__)

  @doc """
  The parity fixture, compiled once per test run and shared: returns
  `module => beam_path` for every module it defines.

  The build directory is keyed by the fixture's sources and the
  compiler versions, and built under a lock, so every module that asks —
  concurrently, async — reads the same beams, and none of them compiles
  the fixture's modules into this VM a second time (a concurrent second
  compile of a module being defined is a compile error). The directory
  goes on the code path, where extraction reads a remote callee's specs
  from, as a project's ebin would be; `use_parity!/1` does the same in a
  peer handed the paths.
  """
  @spec parity!() :: %{optional(module()) => String.t()}
  def parity! do
    digest = parity_key()
    key = {__MODULE__, :parity, digest}

    paths =
      :persistent_term.get(key, nil) ||
        :global.trans({key, self()}, fn ->
          :persistent_term.get(key, nil) ||
            tap(build_parity!(Path.join(System.tmp_dir!(), "scry_parity_#{digest}")), fn paths ->
              :persistent_term.put(key, paths)
            end)
        end)

    use_parity!(paths)
  end

  @doc """
  Puts the parity build directory behind `paths` on the code path (a
  peer's), and returns `paths`.
  """
  @spec use_parity!(%{optional(module()) => String.t()}) :: %{optional(module()) => String.t()}
  def use_parity!(paths) do
    paths |> Map.values() |> hd() |> Path.dirname() |> Code.append_path()
    paths
  end

  defp parity_key do
    sources =
      [Path.join(@parity, "*.ex"), Path.join(@parity, "erl/*.erl")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, @parity), File.read!(&1)})

    {sources, System.version(), :erlang.system_info(:otp_release)}
    |> :erlang.term_to_binary()
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  # Built beside `dest` and renamed into place: a directory under the
  # final name is always complete.
  defp build_parity!(dest) do
    if File.dir?(dest) do
      beams(dest)
    else
      staging = "#{dest}.#{System.unique_integer([:positive])}"
      compile_parity!(staging)

      case File.rename(staging, dest) do
        :ok -> :ok
        {:error, _} -> File.rm_rf!(staging)
      end

      beams(dest)
    end
  end

  @doc """
  Compiles the parity fixture into `dest` (wiped first) and returns
  `module => beam_path` for every module it defines. Tests share one
  build through `parity!/0` instead: this compiles into the calling VM.
  """
  @spec compile_parity!(Path.t()) :: %{optional(module()) => String.t()}
  def compile_parity!(dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)

    elixir = Path.wildcard(Path.join(@parity, "*.ex"))

    # The fixtures define modules this VM may already hold from an earlier
    # compile of the same sources; the conflict warnings are noise here.
    capture_io(:stderr, fn ->
      {:ok, _modules, _warnings} =
        Kernel.ParallelCompiler.compile_to_path(elixir, dest, return_diagnostics: true)
    end)

    for erl <- Path.wildcard(Path.join(@parity, "erl/*.erl")) do
      {:ok, _module} =
        :compile.file(String.to_charlist(erl), [:debug_info, outdir: String.to_charlist(dest)])
    end

    beams(dest)
  end

  defp beams(dir) do
    for path <- Path.wildcard(Path.join(dir, "*.beam")), into: %{} do
      {path |> Path.basename(".beam") |> String.to_atom(), path}
    end
  end

  @doc """
  A database with both layers registered and the driver's inputs set
  the way `Scry.Runner` sets them, over `paths`.
  """
  @spec new_db(%{optional(module()) => String.t()}, keyword()) :: Database.t()
  def new_db(paths, opts \\ []) do
    db = Database.new()
    :ok = Roux.Lang.register_module(db, Scry.Frontend)
    :ok = Roux.Lang.register_module(db, Scry.Analysis)
    :ok = Input.set(db, :env_fingerprint, :all, Keyword.get(opts, :fingerprint, %{test: 1}))
    :ok = Input.set(db, :project_root, :all, File.cwd!())

    # A frontend may leave the rules digests unset (planchette does).
    if Keyword.get(opts, :rules, true) do
      {:ok, all} = Argus.Analysis.set(:all)

      for {key, digest} <- Scry.Fingerprint.rules(all),
          do: :ok = Input.set(db, :rules_digest, key, digest)
    end

    Enum.each(Scry.Analysis.prior_relations(), &(:ok = Input.set(db, :prior_rows, &1, [])))
    sync!(db, paths)
    db
  end

  @doc """
  Brings the database's beam inputs in line with `paths`: new and
  changed beams set, missing ones marked removed.
  """
  @spec sync!(Database.t(), %{optional(module()) => String.t()}) :: :ok
  def sync!(db, paths) do
    for {module, path} <- paths do
      canonical = path |> File.read!() |> Scry.Beam.canonical()
      :ok = Input.set(db, :beam_meta, module, %{path: path, hash: :erlang.md5(canonical)})
    end

    for module <- Input.keys(db, :beam_meta), not Map.has_key?(paths, module) do
      :ok = GC.mark_input_removed(db, :beam_meta, module)
    end

    :ok = Input.set(db, :module_set, :all, paths |> Map.keys() |> Enum.sort())
  end

  @doc """
  Each analysis's solved output rows from the incremental graph.
  """
  @spec incremental(Database.t(), [atom()]) :: %{optional(atom()) => term()}
  def incremental(db, analyses) do
    Map.new(analyses, &{&1, Scry.Analysis.souffle_solve(db, &1)})
  end

  @doc """
  Each analysis's output rows the batch way: one argus extraction of
  every beam, then each analysis's rules over it — `Argus.Findings.run/2`'s
  path, the incremental graph's oracle.
  """
  @spec batch(%{optional(module()) => String.t()}, [atom()]) :: %{optional(atom()) => term()}
  def batch(paths, analyses) do
    {:ok, dir} = Argus.Analysis.extract_facts(Map.values(paths), analyses)

    try do
      analyses
      |> Task.async_stream(
        fn analysis ->
          result =
            case Argus.Analysis.run_rules(dir, analysis) do
              {:ok, rows} ->
                {:ok,
                 rows
                 |> Argus.Analysis.filter_to_outputs(analysis)
                 |> Map.new(fn {relation, rows} -> {relation, Enum.sort(rows)} end)}

              {:error, _} = error ->
                error
            end

          {analysis, result}
        end,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, entry} -> entry end)
    after
      File.rm_rf(Path.dirname(dir))
    end
  end
end
