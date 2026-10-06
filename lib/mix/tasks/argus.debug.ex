defmodule Mix.Tasks.Argus.Debug do
  @shortdoc "Captures and inspects reproducible Datalog investigations"
  @moduledoc """
  Capture a new bundle, then inspect or rerun it without extracting again:

      mix argus.debug capture shutdown tmp/shutdown --module MyApp.Server
      mix argus.debug capture ets tmp/ets --ebin path/to/ebin
      mix argus.debug capture path/to/custom.dl tmp/custom --beam path/to/module.beam
      mix argus.debug relations tmp/shutdown
      mix argus.debug describe tmp/shutdown trap_exit
      mix argus.debug solve tmp/shutdown --probe traps_elsewhere --probe enters_loop_of.reaches
      mix argus.debug rows tmp/shutdown cleanup_defect --where kind=never_runs --limit 10
      mix argus.debug locate tmp/shutdown 'MyApp.Server:init/1#4'
      mix argus.debug source tmp/shutdown SameProcessReach
      mix argus.debug explore tmp/shutdown

  `capture` compiles the current Mix project and accepts repeated `--beam`,
  `--ebin` and `--module` selectors. Without selectors it uses the current
  project's ebin. `--module` selects files in that ebin; external projects'
  beams are read from disk, never added to the VM code path.

  Edit the bundle's `rules/` copy, then use `solve`. Repeated `--probe` names
  intermediate relations, including qualified component relations. Omitting
  `--probe` retains the previous probe list. Use `--restage` after modifying a
  shared-stage rule. A BEAM change needs a fresh capture in a new directory.

  `rows` prints named columns as TSV, with exact `--where column=value` filters
  and a positive `--limit` (default 20). `--from facts|outputs` selects which
  rows to read; the default prefers the latest output. Missing files are errors,
  empty files are empty relations. `describe` shows schema prose, producers and
  rule locations; `source` also finds reusable component definitions.

  Captures include empty classifier priors. They retain all facts, so they can
  be larger and slower to extract than normal incremental analysis. Inspection
  shows tuples and source references, not complete solver provenance or a proof
  of why a tuple is absent. See CONTRIBUTING.md for runnable investigations.

  `explore` opens a Breeze TUI for an existing bundle. Search relations, filter
  and page through rows, follow IDs and rule references to source, and browse
  retained runs. Press `?` for keys and `q` to quit. It reads the bundle without
  compiling the analyzed project or requiring Soufflé. In a consuming project,
  add `{:breeze, "~> 0.5.5"}` to your dependencies to enable the optional TUI.
  If Argus was compiled before Breeze was added, run
  `mix deps.compile argus_beam --force` once.
  """

  use Mix.Task

  alias Argus.Debug

  @switches [
    beam: :keep,
    ebin: :keep,
    module: :keep,
    probe: :keep,
    where: :keep,
    limit: :integer,
    from: :string,
    restage: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [],
      do: Mix.raise("invalid options: #{inspect(invalid)}; see mix help argus.debug")

    if Keyword.get(opts, :help, false) or args == [] do
      Mix.shell().info(@moduledoc)
    else
      execute(args, opts)
    end
  rescue
    error in [ArgumentError, File.Error] -> Mix.raise(Exception.message(error))
  end

  defp execute(["capture", name, root], opts) do
    Argus.Project.Mix.compile!()
    analysis = analysis!(name)
    beams = beams!(opts)
    bundle = Debug.capture!(beams, analysis, root, probes: Keyword.get_values(opts, :probe))

    Mix.shell().info(
      "Captured #{bundle}. Use rows, describe, source, locate or solve to investigate."
    )
  end

  defp execute(["solve", root], opts) do
    options = Keyword.take(opts, [:restage])
    probes = Keyword.get_values(opts, :probe)
    options = if probes == [], do: options, else: Keyword.put(options, :probes, probes)
    run = Debug.solve!(root, options)
    Mix.shell().info("Solved into #{run}; previous runs remain in the bundle's runs/ directory.")
  end

  defp execute(["explore", root], _opts) do
    if System.get_env("TERM") == "dumb" or not Keyword.get(:io.getopts(), :terminal, false) do
      Mix.raise(
        "explore needs an interactive terminal with raw keyboard input; TERM=dumb is unsupported"
      )
    end

    Argus.Debug.Explorer.run!(root)
  end

  defp execute(["relations", root], _opts) do
    root |> Debug.relations!() |> Enum.each(fn name -> Mix.shell().info(name) end)
  end

  defp execute(["describe", root, name], _opts) do
    definition = Debug.describe!(root, name)
    Mix.shell().info(name)
    if definition.doc, do: Mix.shell().info(definition.doc)

    for field <- definition.fields do
      Mix.shell().info("  #{field["name"]}: #{field["type"]}  #{field["doc"]}")
    end

    for producer <- definition.producers do
      Mix.shell().info("Producer: #{producer["module"]} (#{producer["file"]})")
    end

    show_sources(root, definition.sources)
  end

  defp execute(["source", root, name], _opts) do
    manifest = Debug.manifest!(root)
    show_sources(root, Argus.Debug.Program.sources(root, manifest["program"], name))
  end

  defp execute(["rows", root, name], opts) do
    filters = Enum.map(Keyword.get_values(opts, :where), &filter!/1)

    from =
      case Keyword.get(opts, :from, "auto") do
        "auto" -> :auto
        "facts" -> :facts
        "outputs" -> :outputs
        other -> raise ArgumentError, "unknown row source #{other}; use facts or outputs"
      end

    table =
      Debug.rows!(root, name, where: filters, limit: Keyword.get(opts, :limit, 20), from: from)

    IO.write(Argus.Tsv.encode([table.fields | table.rows]))
    if table.rows == [], do: Mix.shell().info("(no matching rows)")
    if table.more?, do: Mix.shell().info("(more matching rows; increase --limit or add --where)")
  end

  defp execute(["locate", root, id], _opts) do
    location = Debug.locate!(root, id)

    Mix.shell().info(
      "#{id}  #{location.file || "source unavailable"}:#{location.line || "line unavailable"}"
    )
  end

  defp execute(_args, _opts),
    do:
      Mix.raise(
        "expected capture, solve, relations, describe, rows, source, locate or explore; see mix help argus.debug"
      )

  defp show_sources(root, sources) do
    for source <- Enum.take(sources, 30) do
      Mix.shell().info("#{Path.expand(source.path, root)}:#{source.line}: #{source.text}")
    end

    if length(sources) > 30,
      do: Mix.shell().info("(#{length(sources) - 30} more source references)")

    if sources == [], do: Mix.shell().info("(no matching source references)")
  end

  defp filter!(filter) do
    case String.split(filter, "=", parts: 2) do
      [column, value] when column != "" -> {column, value}
      _ -> raise ArgumentError, "expected --where column=value, got #{inspect(filter)}"
    end
  end

  defp analysis!(name) do
    Enum.find(Argus.Analysis.builtin_analyses(), &(Atom.to_string(&1) == name)) ||
      if(File.regular?(name),
        do: {:custom, Path.expand(name)},
        else:
          raise(
            ArgumentError,
            "unknown analysis #{name}; use mix argus --list or a .dl program path"
          )
      )
  end

  defp beams!(opts) do
    files = Keyword.get_values(opts, :beam)
    ebins = Keyword.get_values(opts, :ebin)
    modules = Keyword.get_values(opts, :module)
    dir = Mix.Project.compile_path()

    selected =
      for name <- modules do
        encoded =
          cond do
            String.starts_with?(name, "Elixir.") -> name
            Regex.match?(~r/^[A-Z]/, name) -> "Elixir." <> name
            true -> String.trim_leading(name, ":")
          end

        path = Path.join(dir, encoded <> ".beam")

        unless File.regular?(path),
          do:
            raise(
              ArgumentError,
              "no BEAM for #{name} in #{dir}; use --beam for an external module"
            )

        path
      end

    ebins = if files == [] and ebins == [] and modules == [], do: [dir], else: ebins

    for ebin <- ebins do
      unless File.dir?(ebin), do: raise(ArgumentError, "ebin directory #{ebin} does not exist")
    end

    beams =
      Enum.uniq(
        files ++ selected ++ Enum.flat_map(ebins, &Path.wildcard(Path.join(&1, "*.beam")))
      )

    if beams == [],
      do:
        raise(
          ArgumentError,
          "no BEAM inputs found; compile the project or select --beam/--ebin/--module"
        )

    beams
  end
end
