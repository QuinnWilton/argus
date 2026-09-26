defmodule Argus.Graph.Frontend do
  @moduledoc """
  The disk-beam roux frontend: `Argus.Graph`'s frontend contract,
  satisfied from the `.beam` files the stock compilers just produced.

  Registers the same query names as planchette's in-memory compile
  frontend — roux dispatches by name, so the shared analysis layer works
  over either without change. What this frontend provides:

  - `:beam_meta` input — `module => %{path, hash}`. The driver
    (`Argus.Project.Scan`) sets it from an mtime/size-prefiltered scan, hashing
    content only for files that moved; a recompiled-but-identical beam
    produces an equal value and advances nothing.
  - `:module_set` input — `:all => sorted [module]`, the project's
    analyzed modules.
  - `:ignored_beam` input — `module => %{path, hash}` for each module the
    `ignore` config keeps out of analysis. Never analyzed, but on the
    code path, where a caller's extraction reads its specs; the edge
    from that caller to this key is what re-extracts it when the
    ignored beam changes.
  - `:env_fingerprint` input — `:all =>` toolchain map
    (`Argus.Graph.Environment.env/2`); `:high` durability so an upgrade
    invalidates the whole graph.
  - `:extraction_code` input — `:all =>` a digest of the code argus's
    fact producers run (`Argus.Graph.Environment.extraction_code/0`): an
    extractor edit re-extracts every module, and an argus edit outside
    that code extracts nothing.
  - `:argus_code` input — `:all =>` a digest of every argus beam
    (`Argus.Graph.Environment.argus_code/1`): what the findings are built by,
    and what a program calling argus reads specs from.
  - `:rules_digest` input — analysis (or shared stage program:
    `:stage0`, `:points_to`, `:points_to_bounded`) `=>` a digest of
    the Datalog it runs, as its solve loads it
    (`Argus.Graph.Environment.rules/2`); a rule edit re-solves the analyses
    whose programs it touched and re-extracts nothing.
  - `:module_beam` query — beam bytes, read from disk. The read itself is
    untracked; the tracked signal is the `:beam_meta` value, and roux's
    early cutoff backdates downstream work when re-read bytes compare
    equal (a `touch` re-reads one file and recomputes nothing else).
  - `:module_source` / `:module_map` / `:file_of` queries — source
    attribution from each beam's `compile_info`.

  Durability: everything here is `:medium` or `:high` — never `:low`.
  Durability propagates as the minimum over dependencies, and `:low`
  derived memos are dropped from the manifest, which would evict the
  fact memos that make warm starts worth having.

  Planchette's focus surface (`Planchette.Focus`) additionally wants
  `:source_text` and `:declared_modules`; this frontend deliberately
  does not provide them — the compiler never demands those queries, and
  roux is demand-driven, so their absence costs nothing.
  """

  use Roux.Query

  alias Roux.Runtime

  definput(:beam_meta, durability: :medium)
  definput(:module_set, durability: :medium)
  definput(:ignored_beam, durability: :medium)
  definput(:env_fingerprint, durability: :high)
  definput(:extraction_code, durability: :high)
  definput(:argus_code, durability: :high)
  definput(:rules_digest, durability: :high)

  # The project's root directory, for a beam whose recorded source path
  # belongs to the machine that compiled it (a moved checkout, a Docker
  # build): the same path relative to this root is looked for instead.
  definput(:project_root, durability: :high)

  # One key per layer-3 relation: the classifier's rows (`Argus.Graph.Priors`),
  # interned, or `[]` when priors are off. An input rather than a query
  # because a derived value at `:low` durability is dropped from the
  # manifest and the network call it stands for is the one thing a warm
  # run must not repeat; and set by the runner outside the graph, since
  # a query cannot set an input.
  definput(:prior_rows, durability: :medium)

  # One key per module: 0, or a fresh value on a run that retries the
  # module's extraction because the last one failed (a timeout under load
  # is not a fact about the beam). `module_extraction` reads it only when
  # set.
  definput(:extraction_attempt, durability: :medium)

  # `:all =>` the layout of the graph the manifest was written by
  # (`Argus.Driver`): a manifest of another is dropped before anything
  # reads it. Driver bookkeeping no query reads, so `:low`.
  definput(:graph_layout, durability: :low)

  # `:all =>` the modules whose last extraction failed, for the next run
  # to retry. Driver bookkeeping no query reads; `:low` so that setting it
  # after the analyses ran never makes the next run revalidate them.
  definput(:failed_extractions, durability: :low)

  defquery :module_beam, key: module, returns: {:ok, binary()} | :external | {:error, term()} do
    case Runtime.input(db, :beam_meta, module) do
      nil ->
        # Not a scanned module: a related anchor pointing outside the
        # project. The shared layer matches on this exact atom.
        :external

      %{path: path} ->
        case File.read(path) do
          {:ok, beam} -> {:ok, Argus.Graph.Beam.canonical(beam)}
          {:error, reason} -> {:error, {:beam_read, module, reason}}
        end
    end
  end

  # The source path a module's diagnostics anchor to, from the beam's own
  # compile_info. Per-module so that a beam edit recomputes one path,
  # compares equal, and backdates — module_map above it then validates
  # without executing.
  defquery :module_source, key: module, returns: String.t() | :external do
    case Runtime.input(db, :beam_meta, module) do
      nil ->
        :external

      %{path: beam_path} ->
        case Runtime.query(db, :module_beam, module) do
          {:ok, beam} -> source_path(beam, beam_path, Runtime.input!(db, :project_root, :all))
          _other -> :external
        end
    end
  end

  defquery :module_map, key: :all, returns: %{optional(module()) => String.t()} do
    for module <- Runtime.input!(db, :module_set, :all),
        path = Runtime.query(db, :module_source, module),
        path != :external,
        into: %{} do
      {module, path}
    end
  end

  # Per-module projection of module_map — the shape the shared layer's
  # anchor resolution demands. `:external` for anything outside the map.
  defquery :file_of, key: module, returns: String.t() | :external do
    Map.get(Runtime.query(db, :module_map, :all), module, :external)
  end

  # The compiler recorded the source absolute-at-compile-time. When the
  # file is not there — a checkout that moved, a release built elsewhere
  # — the longest tail of that path that exists under the project root
  # is it (`lib/app/x.ex` for an app, `apps/app/lib/app/x.ex` for an
  # umbrella member). Failing that, stripped compile_info included, the
  # beam path itself: a visible, honest anchor beats silently dropping
  # the module's findings (its facts still feed every cross-module
  # analysis either way).
  defp source_path(beam, beam_path, root) do
    with {:ok, {_mod, [compile_info: info]}} <- :beam_lib.chunks(beam, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source, :missing),
         path = Path.expand(to_string(source)),
         {:ok, found} <- recorded_or_relocated(path, root) do
      found
    else
      _ -> beam_path
    end
  end

  defp recorded_or_relocated(path, root) do
    if File.exists?(path) do
      {:ok, path}
    else
      path
      |> Path.split()
      |> Enum.drop(1)
      |> Stream.iterate(&tl/1)
      |> Enum.take_while(&(&1 != []))
      |> Enum.map(&Path.join([root | &1]))
      |> Enum.find(&File.regular?/1)
      |> case do
        nil -> :error
        found -> {:ok, found}
      end
    end
  end
end
