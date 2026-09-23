defmodule Scry.Scanner do
  @moduledoc """
  Beam discovery and change detection for the compiler driver.

  `scan/1` globs the project's ebin (and dependency ebins when
  `include_deps` is set) into a `module => beam_path` map, applying
  module-level ignores at discovery so ignored modules are never even
  extracted.

  `sync/3` diffs the scan against the previous run's source metadata and
  updates the roux inputs: an mtime+size match skips the file without
  reading it (mix-grade staleness, same trade as the Elixir compiler);
  anything else is read and content-hashed, and `Input.set`'s equality
  cutoff absorbs recompiled-but-identical beams. Modules whose beams are
  gone are GC'd out of the input space.
  """

  alias Roux.Database
  alias Roux.GC
  alias Roux.Input

  @typedoc "Per-beam manifest metadata: the mtime+size prefilter plus a content hash."
  @type meta :: %{mtime: integer(), size: non_neg_integer(), hash: binary()}

  @typedoc "The result of syncing a scan into the database."
  @type sync_result :: %{
          sources: %{optional(String.t()) => meta()},
          changed: [module()],
          removed: [module()]
        }

  @typedoc """
  A module found in more than one ebin: the beam analyzed, and the ones
  passed over.
  """
  @type duplicate :: %{module: module(), used: String.t(), shadowed: [String.t()]}

  @typedoc "What a scan found."
  @type scan :: %{modules: %{optional(module()) => String.t()}, duplicates: [duplicate()]}

  @typedoc """
  A project's scan, with the applications whose ebins it read (`apps`):
  the scan watches their beams, so the environment fingerprint leaves
  them out.
  """
  @type project_scan :: %{
          modules: %{optional(module()) => String.t()},
          duplicates: [duplicate()],
          apps: [atom()]
        }

  @doc """
  Discovers the beams to analyze: `module => beam_path`, plus every
  module more than one ebin defines (`include_deps` only), and the
  applications whose ebins were read.
  """
  @spec scan(Scry.Config.t()) :: project_scan()
  def scan(%Scry.Config{} = config) do
    ebins =
      if config.include_deps do
        [Mix.Project.compile_path() | dep_ebins()]
      else
        [Mix.Project.compile_path()]
      end

    ebins
    |> discover(config.ignore_modules)
    |> Map.put(:apps, Enum.map(ebins, &app_of/1))
  end

  # Mix builds each application into `<build>/lib/<app>/ebin`.
  defp app_of(ebin), do: ebin |> Path.dirname() |> Path.basename() |> String.to_atom()

  @doc """
  The beams in `ebins`, minus the modules `ignore` matches (regexes over
  the inspected name, or module atoms).

  A module defined in more than one ebin is taken from the first that
  has it — callers list the project's own ebin first and the rest in a
  fixed order — and reported as a duplicate, never resolved by whichever
  directory happened to be read last.
  """
  @spec discover([String.t()], [Regex.t() | module()]) :: scan()
  def discover(ebins, ignore) do
    found =
      for ebin <- ebins,
          path <- ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort(),
          module = module_of(path),
          not ignored_module?(module, ignore),
          do: {module, path}

    by_module = Enum.group_by(found, &elem(&1, 0), &elem(&1, 1))

    duplicates =
      for {module, [used | shadowed]} <- Enum.sort(by_module), shadowed != [] do
        %{module: module, used: used, shadowed: shadowed}
      end

    %{
      modules: Map.new(by_module, fn {module, [path | _]} -> {module, path} end),
      duplicates: duplicates
    }
  end

  @doc """
  Syncs a scan into the database inputs, diffing against the prior run's
  source metadata (the manifest's `sources` map). Returns the fresh
  metadata to persist, plus which modules changed or disappeared.
  """
  @spec sync(Database.t(), %{optional(module()) => String.t()}, %{
          optional(String.t()) => meta()
        }) :: sync_result()
  def sync(%Database{} = db, discovered, prior_sources) do
    now = System.os_time(:second)

    {sources, changed, gone} =
      Enum.reduce(discovered, {%{}, [], []}, fn {module, path}, {sources, changed, gone} ->
        case sync_one(db, module, path, Map.get(prior_sources, path), now) do
          {:unchanged, meta} -> {Map.put(sources, path, meta), changed, gone}
          {:changed, meta} -> {Map.put(sources, path, meta), [module | changed], gone}
          :gone -> {sources, changed, [module | gone]}
        end
      end)

    # A beam deleted between the glob and here — a concurrent compile
    # pruning it — is simply not part of the project this run.
    present = Map.drop(discovered, gone)
    removed = mark_removed(db, present)

    module_set = present |> Map.keys() |> Enum.sort()
    :ok = Input.set(db, :module_set, :all, module_set)

    %{sources: sources, changed: Enum.sort(changed), removed: removed}
  end

  defp sync_one(db, module, path, prior, now) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        sync_present(db, module, path, prior, now, mtime, size)

      {:error, _} ->
        :gone
    end
  end

  defp sync_present(db, module, path, prior, now, mtime, size) do
    case prior do
      %{mtime: ^mtime, size: ^size} when mtime < now - 1 ->
        # The prefilter: an untouched file is never read. Files written
        # within the last second are exempt — mtime has one-second
        # granularity, and scry runs moments after :elixir, so a
        # fast edit-compile-edit-compile sequence can rewrite a beam in
        # the same second with the same size. Recent files get
        # content-hashed; on a warm noop nothing is recent and nothing
        # is read.
        {:unchanged, prior}

      _ ->
        case File.read(path) do
          {:ok, raw} -> hash_and_set(db, module, path, prior, mtime, size, raw)
          {:error, _} -> :gone
        end
    end
  end

  defp hash_and_set(db, module, path, prior, mtime, size, raw) do
    # Hashed in canonical form: a dependent module Elixir rewrote only to
    # refresh its ExCk chunk must not read as a changed input.
    hash = raw |> Scry.Beam.canonical() |> :erlang.md5()
    meta = %{mtime: mtime, size: size, hash: hash}

    # Equal hash means a touch or a byte-identical recompile: the input
    # value is unchanged, so Input.set's cutoff advances nothing and the
    # run stays a noop.
    changed? = not match?(%{hash: ^hash}, prior)
    :ok = Input.set(db, :beam_meta, module, %{path: path, hash: hash})

    if changed?, do: {:changed, meta}, else: {:unchanged, meta}
  end

  defp mark_removed(db, discovered) do
    removed =
      for module <- Input.keys(db, :beam_meta),
          not Map.has_key?(discovered, module) do
        :ok = GC.mark_input_removed(db, :beam_meta, module)
        module
      end

    Enum.sort(removed)
  end

  # basename → module. `String.to_atom`, not `to_existing_atom`: the
  # env-scoped ebin the compiler chain just wrote is authoritative (this
  # is not `mix argus`'s cross-env glob), and the atom count is bounded
  # by project size.
  defp module_of(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end

  defp ignored_module?(module, patterns) do
    name = inspect(module)

    Enum.any?(patterns, fn
      %Regex{} = regex -> Regex.match?(regex, name)
      atom when is_atom(atom) -> atom == module
    end)
  end

  # Sorted, so which of two dependencies defining a module wins does not
  # depend on the filesystem's listing order.
  defp dep_ebins do
    Mix.Project.build_path()
    |> Path.join("lib/*/ebin")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == Mix.Project.compile_path()))
    |> Enum.sort()
  end
end
