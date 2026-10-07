defmodule Argus.Debug do
  @moduledoc """
  Reproducible, editable analysis bundles for contributor investigations.

  `capture!/4` writes all bytecode and domain facts, the shared stages, a copy
  of the rules, and raw outputs to a new directory. `solve!/2` reruns that copy
  without extracting again. Add `probes: ["traps_elsewhere",
  "enters_loop_of.reaches"]` to output intermediate relations in a private
  wrapper, leaving the production rules untouched.

  This opt-in path uses the existing pipeline and shared stages. It deliberately
  retains the instruction-level relations normal graph solves omit. It does not
  read or modify the normal query graph's manifests or cache layout.

  Rows and rule locations are inspection evidence, not a complete derivation
  proof or an explanation of why a tuple is missing. A changed shared-stage
  program needs `solve!(bundle, restage: true)`; a changed BEAM needs a new capture.
  """

  alias Argus.Analysis
  alias Argus.Debug.Program
  alias Argus.{Lines, Relation, Schema, Tsv}
  alias Argus.Pipeline.Disassemble

  @doc """
  Capture `modules` (BEAM paths, module atoms, or BEAM binaries) for `analysis`.

  The destination must not exist. `:extractors` adds custom producers to the
  built-ins; their empty outputs are retained too. `:probes` names intermediate
  relations. `:timeout`, `:workers` and `:concurrency` are forwarded to the
  existing implementations. Each run compiles its program's FlowLog engine
  unless one was built for the same rules before (`Argus.FlowLog.Program`):
  an edited rule costs a build. Captures contain no optional classifier
  priors; `prior_*` inputs are empty and this is recorded in the manifest.

  Returns the absolute bundle path. Failure leaves the newly created bundle
  for inspection, never removes a caller's existing directory, and does not
  publish a successful run.
  """
  @spec capture!([Disassemble.module_input()], Analysis.analysis(), Path.t(), keyword()) ::
          Path.t()
  def capture!(modules, analysis, destination, opts \\ []) do
    _ = toolchain!()
    {:ok, rules} = analysis_path!(analysis)
    beams = unwrap!(Disassemble.resolve_paths(modules), "resolve BEAM inputs")
    root = Path.expand(destination)
    File.mkdir_p!(Path.dirname(root))

    case File.mkdir(root) do
      :ok -> :ok
      {:error, :eexist} -> raise ArgumentError, "bundle #{root} already exists; choose a new path"
      {:error, reason} -> raise File.Error, reason: reason, action: "create bundle", path: root
    end

    program = Program.copy!(rules, root)

    extractors =
      Enum.uniq(Argus.Graph.Extraction.extractors() ++ Keyword.get(opts, :extractors, []))

    facts = Path.join(root, "facts")

    pipeline_opts =
      Keyword.take(opts, [:concurrency]) ++ [extractors: extractors, trace_imprecision: true]

    unwrap!(Argus.Pipeline.run(beams, facts, pipeline_opts), "extract facts")

    manifest = %{
      "version" => 1,
      "analysis" => if(is_atom(analysis), do: Atom.to_string(analysis), else: nil),
      "program" => program,
      "priors" => "none; prior_* relations are empty",
      "solver" => "FlowLog " <> Argus.FlowLog.Native.flowlog_revision(),
      "sources" => sources(beams),
      "schema" => Map.new(Schema.all(), &{Atom.to_string(&1.name), definition(&1)}),
      "outputs" => output_definitions(analysis),
      "producers" => producers(extractors)
    }

    write_json!(Path.join(root, "bundle.json"), manifest)
    solve!(root, Keyword.put(opts, :restage, true))
    root
  end

  @doc """
  Rerun the bundle's editable rules. Publish the latest run only on success.

  `:probes` replaces the last run's probe list; omit it to retain that list.
  `:restage` recomputes stage 0 and points-to over the retained extracted facts
  using the bundle's own rules. Old run directories remain available for
  comparison, including after a failed compile or solve.
  """
  @spec solve!(Path.t(), keyword()) :: Path.t()
  def solve!(root, opts \\ []) do
    root = Path.expand(root)
    manifest = manifest!(root)
    _ = toolchain!()
    previous = latest(root)
    probes = Keyword.get(opts, :probes, Map.get(previous, "probes", []))
    relative = new_run!(root)
    run = Path.join(root, relative)
    path = Program.wrapper!(root, manifest["program"], run, probes)
    columns = Program.columns!(path, run)
    facts = Path.join(run, "facts")
    File.cp_r!(facts_path(root, previous), facts)
    solver_opts = Keyword.take(opts, [:timeout, :workers])

    stage_columns =
      if Keyword.get(opts, :restage, false) do
        stage0 = Path.join(run, "rules/stage0.dl")

        unwrap!(
          Analysis.Extraction.derive_stage0(facts, [rules_path: stage0] ++ solver_opts),
          "derive stage 0"
        )

        stages = Program.columns!(stage0, run, "stage0.relations.json")

        if Analysis.Extraction.reads_points_to?({:custom, path}, solver_opts) do
          restage_points_to!(run, facts, solver_opts)
          points_to = Path.join(run, "rules/points_to.dl")
          Map.merge(stages, Program.columns!(points_to, run, "points_to.relations.json"))
        else
          stages
        end
      else
        Map.get(previous, "stage_columns", %{})
      end

    outputs =
      unwrap!(Argus.FlowLog.run(facts, path, [output_dir: run] ++ solver_opts), "solve rules")

    snapshot = %{
      "directory" => relative,
      "probes" => probes,
      "columns" => Map.merge(stage_columns, columns),
      "stage_columns" => stage_columns,
      "outputs" => Enum.sort(Map.keys(outputs))
    }

    write_json!(Path.join(run, "run.json"), snapshot)
    write_json!(Path.join(root, "latest.json"), snapshot)

    run
  end

  defp restage_points_to!(root, facts, opts) do
    # Reuse the existing bounded fallback with explicit paths instead of mutating
    # the application's dl_root (which would affect concurrent graph sessions).
    unwrap!(
      Analysis.Extraction.derive_points_to(
        facts,
        [
          rules_path: Path.join(root, "rules/points_to.dl"),
          bounded_rules_path: Path.join(root, "rules/points_to_bounded.dl")
        ] ++ opts
      ),
      "derive points-to"
    )
  end

  @doc "The manifest of a captured bundle; missing or unsupported bundles raise."
  @spec manifest!(Path.t()) :: map()
  def manifest!(root) do
    manifest = root |> Path.join("bundle.json") |> File.read!() |> JSON.decode!()
    unless manifest["version"] == 1, do: raise(ArgumentError, "unsupported debug bundle version")
    manifest
  end

  @doc "Names of captured fact relations and the latest run's output relations."
  @spec relations!(Path.t(), keyword()) :: [String.t()]
  def relations!(root, opts \\ []) do
    manifest!(root)
    latest = snapshot!(root, opts)

    facts =
      root
      |> facts_path(latest)
      |> Path.join("*.facts")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".facts"))

    Enum.sort(Enum.uniq(facts ++ Map.get(latest, "outputs", [])))
  end

  @doc "Column definitions, schema/report prose, producers and matching rule locations."
  @spec describe!(Path.t(), String.t(), keyword()) :: map()
  def describe!(root, name, opts \\ []) do
    manifest = manifest!(root)
    describe(root, name, manifest, snapshot!(root, opts), Keyword.get(opts, :run))
  end

  defp describe(root, name, manifest, latest, run) do
    definition = manifest["schema"][name] || manifest["outputs"][name] || %{}
    captured = Map.get(definition, "fields")
    compiled = Map.get(latest["columns"] || %{}, name)

    # Keep the captured semantic types and prose when the column contract still
    # matches. A declaration edited in the bundle must show its actual columns.
    columns =
      if captured && compiled &&
           Enum.map(captured, & &1["name"]) != Enum.map(compiled, & &1["name"]),
         do: compiled,
         else: captured || compiled

    if columns == nil do
      raise ArgumentError,
            "unknown relation #{name}; solve with --probe #{name} to expose an intermediate relation"
    end

    %{
      name: name,
      fields: columns,
      doc: Map.get(definition, "doc"),
      producers: Map.get(manifest["producers"], name, []),
      sources: rule_sources(root, manifest, latest, name, run)
    }
  end

  @doc """
  Inspect rows with `:where` named-column equality filters, `:limit` (default 20),
  and `:offset` (default 0, after filtering). Pagination streams the file; it
  does not load the whole relation. `:run` selects a retained run directory;
  omit it to inspect the latest successful solve.

  `:from` is `:auto` (prefer the latest output), `:facts`, or `:outputs`.
  Returns fields, bounded raw rows and whether another matching row exists.
  Missing relation files raise; a zero-byte relation is an empty result.
  """
  @spec rows!(Path.t(), String.t(), keyword()) ::
          %{fields: [String.t()], rows: [[String.t()]], more?: boolean(), path: Path.t()}
  def rows!(root, name, opts \\ []) do
    latest = snapshot!(root, opts)
    description = describe(root, name, manifest!(root), latest, Keyword.get(opts, :run))
    fields = Enum.map(description.fields, & &1["name"])
    limit = Keyword.get(opts, :limit, 20)
    unless is_integer(limit) and limit > 0, do: raise(ArgumentError, "limit must be positive")
    offset = Keyword.get(opts, :offset, 0)

    unless is_integer(offset) and offset >= 0,
      do: raise(ArgumentError, "offset must be non-negative")

    output = Path.join([root, Map.get(latest, "directory", "runs/missing"), "#{name}.csv"])
    fact = Path.join(facts_path(root, latest), "#{name}.facts")

    path =
      case Keyword.get(opts, :from, :auto) do
        :auto -> if(name in Map.get(latest, "outputs", []), do: output, else: fact)
        :facts -> fact
        :outputs -> output
        other -> raise ArgumentError, "unknown row source #{inspect(other)}"
      end

    unless File.regular?(path) do
      raise ArgumentError,
            "missing relation file #{path}; solve with --probe #{name} for intermediate rows"
    end

    rows =
      path
      |> File.stream!()
      |> Stream.flat_map(&Tsv.decode/1)
      |> Stream.map(fn row -> if fields == [] and row == [""], do: [], else: row end)
      |> Relation.stream(fields, where: Keyword.get(opts, :where, []))
      |> Stream.drop(offset)
      |> Enum.take(limit + 1)

    %{fields: fields, rows: Enum.take(rows, limit), more?: length(rows) > limit, path: path}
  end

  @doc """
  Metadata for a successful solve. `:run` accepts `runs/<name>` from `runs!/1`.
  Older bundles retain metadata only for their latest run; selecting an older
  run without metadata raises instead of interpreting it with newer columns.
  """
  @spec snapshot!(Path.t(), keyword()) :: map()
  def snapshot!(root, opts \\ []) do
    case Keyword.get(opts, :run) do
      nil ->
        latest(root)

      directory ->
        unless is_binary(directory) and Path.dirname(directory) == "runs" and
                 Path.basename(directory) not in [".", ".."],
               do: raise(ArgumentError, "expected a run directory of the form runs/<name>")

        path = Path.join([root, directory, "run.json"])

        case File.read(path) do
          {:ok, json} ->
            snapshot = JSON.decode!(json)
            Map.put(snapshot, "directory", directory)

          {:error, :enoent} ->
            snapshot = latest(root)

            if snapshot["directory"] == directory,
              do: snapshot,
              else: raise(ArgumentError, "#{directory} has no successful run metadata")

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read run", path: path
        end
    end
  end

  @doc "Retained run directories, including incomplete and older unindexed runs."
  @spec runs!(Path.t()) ::
          [%{directory: Path.t(), latest?: boolean(), indexed?: boolean()}]
  def runs!(root) do
    current = latest(root)["directory"]

    root
    |> Path.join("runs/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
    |> Enum.map(fn path ->
      directory = Path.relative_to(path, root)

      %{
        directory: directory,
        latest?: directory == current,
        indexed?: File.regular?(Path.join(path, "run.json")) or directory == current
      }
    end)
  end

  defp rule_sources(root, manifest, snapshot, name, run) do
    if run do
      directory = snapshot["directory"]
      base = Path.join(root, directory)

      for source <- Program.sources(base, manifest["program"], name),
          do: %{source | path: Path.join(directory, source.path)}
    else
      Program.sources(root, manifest["program"], name)
    end
  end

  @doc "Resolve an instruction or function ID using the bundle's retained line facts."
  @spec locate!(Path.t(), String.t()) :: map()
  def locate!(root, id) do
    parsed =
      case Argus.InstrId.parse(id) do
        {:ok, instr} -> {:ok, Map.from_struct(instr)}
        :error -> Argus.InstrId.parse_func(id)
      end

    case parsed do
      {:ok, %{module: module} = parts} ->
        source = manifest!(root)["sources"][module]
        line = root |> Path.join("facts") |> Lines.from_facts_dir() |> Lines.resolve(id)
        Map.merge(parts, %{id: id, file: source, line: line})

      :error ->
        raise ArgumentError, "#{inspect(id)} is not a function or instruction ID"
    end
  end

  defp latest(root) do
    case File.read(Path.join(root, "latest.json")) do
      {:ok, json} -> JSON.decode!(json)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise File.Error, reason: reason, action: "read latest run", path: root
    end
  end

  defp new_run!(root) do
    File.mkdir_p!(Path.join(root, "runs"))
    relative = "runs/#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"

    case File.mkdir(Path.join(root, relative)) do
      :ok -> relative
      {:error, :eexist} -> new_run!(root)
      {:error, reason} -> raise File.Error, reason: reason, action: "create run", path: root
    end
  end

  defp definition(relation) do
    %{
      "doc" => relation.doc,
      "fields" =>
        Enum.map(relation.fields, fn {name, type, doc} ->
          %{"name" => Atom.to_string(name), "type" => Atom.to_string(type), "doc" => doc}
        end)
    }
  end

  defp facts_path(root, %{"directory" => directory}), do: Path.join([root, directory, "facts"])
  defp facts_path(root, _no_run), do: Path.join(root, "facts")

  defp output_definitions(name) when is_atom(name) do
    {:ok, outputs} = Analysis.output_relations(name)
    Map.new(outputs, &{Atom.to_string(&1.name), definition(&1)})
  end

  defp output_definitions({:custom, _}), do: %{}

  defp sources(beams) do
    Map.new(beams, fn beam ->
      {:ok, data} = Disassemble.disassemble_path(beam)

      path =
        case BeamSpy.BeamFile.read_compile_info(beam) do
          {:ok, info} -> info |> Keyword.get(:source) |> source_string()
          _ -> nil
        end

      {inspect(data.module), path}
    end)
  end

  defp source_string(nil), do: nil
  defp source_string(path), do: to_string(path)

  defp producers(extractors) do
    extracted = for extractor <- extractors, name <- extractor.relations(), do: {name, extractor}
    named = MapSet.new(extracted, &elem(&1, 0))

    base_names =
      Enum.map(Schema.layer_1(), & &1.name) ++
        [:def_use, :conditional_call, :site_block, :block_flow, :extraction_error, :imprecision]

    base = for name <- base_names, not MapSet.member?(named, name), do: {name, Argus.Pipeline}

    (base ++ extracted)
    |> Enum.group_by(fn {name, _} -> Atom.to_string(name) end, fn {_, module} ->
      %{
        "module" => inspect(module),
        "file" => source_string(module.module_info(:compile)[:source])
      }
    end)
  end

  defp toolchain! do
    case Argus.FlowLog.toolchain() do
      {:ok, toolchain} -> toolchain
      {:error, reason} -> raise ArgumentError, Argus.FlowLog.describe_error(reason)
    end
  end

  defp analysis_path!(analysis) do
    case Analysis.Catalog.rules_path(analysis) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> raise ArgumentError, "cannot select analysis: #{inspect(reason)}"
    end
  end

  defp unwrap!({:ok, value}, _action), do: value
  defp unwrap!(:ok, _action), do: :ok

  defp unwrap!({:error, reason}, action),
    do: raise(ArgumentError, "could not #{action}: #{inspect(reason, limit: :infinity)}")

  defp write_json!(path, value) do
    scratch = "#{path}.#{:os.getpid()}.#{System.unique_integer([:positive])}"
    File.write!(scratch, JSON.encode!(value))
    File.rename!(scratch, path)
  end
end
