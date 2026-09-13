defmodule Mix.Tasks.Argus do
  @shortdoc "Run BEAM program analysis via Souffle Datalog"

  @moduledoc """
  Runs Argus analysis against project modules.

  ## Usage

      mix argus ANALYSIS [options]

  Run `mix argus --list` to see all available analyses with descriptions.

  ## Custom analysis

      mix argus custom path/to/rules.dl

  ## Options

  - `--modules` — comma-separated list of modules to analyze (default: all project modules)
  - `--include-deps` — include dependency modules in analysis
  - `--format` — output format: text (default) or json
  - `--fail-above N` — exit with non-zero status if more than N results
  - `--concurrency N` — parallel extraction workers (default: number of schedulers)
  - `--list` — list all available analyses with descriptions

  ## Examples

      mix argus supervision
      mix argus ets --modules MyApp.Cache
      mix argus unsafe_task --fail-above 0
      mix argus custom my_rules.dl
      mix argus --list
  """

  use Mix.Task

  alias Argus.Analysis

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          modules: :string,
          include_deps: :boolean,
          format: :string,
          fail_above: :integer,
          concurrency: :integer,
          list: :boolean
        ]
      )

    if opts[:list] do
      print_analyses()
    else
      unless Argus.Souffle.available?() do
        Mix.raise(Argus.Souffle.not_found_message())
      end

      case positional do
        [] ->
          Mix.raise(
            "Usage: mix argus ANALYSIS [options]\nRun `mix argus --list` for available analyses."
          )

        ["custom", rules_path | _] ->
          run_analysis({:custom, rules_path}, opts)

        [analysis_name | _] ->
          case parse_analysis(analysis_name) do
            {:ok, analysis} -> run_analysis(analysis, opts)
            {:error, msg} -> Mix.raise(msg)
          end
      end
    end
  end

  defp print_analyses do
    modules = Analysis.builtin_analysis_modules()

    if modules == [] do
      Mix.shell().info("No analyses found.")
    else
      header = "Available analyses:\n"

      lines =
        Enum.map_join(modules, "\n", fn mod ->
          "  #{mod.name()} — #{mod.description()}"
        end)

      Mix.shell().info(header <> lines)
    end
  end

  defp parse_analysis(name) do
    case Enum.find(Analysis.builtin_analyses(), &(to_string(&1) == name)) do
      nil ->
        available =
          Analysis.builtin_analysis_modules()
          |> Enum.map_join("\n  ", fn mod -> "#{mod.name()} — #{mod.description()}" end)

        {:error, "Unknown analysis: #{name}\n\nAvailable analyses:\n  #{available}"}

      atom ->
        {:ok, atom}
    end
  end

  defp run_analysis(analysis, opts) do
    modules = resolve_modules(opts)
    format = Keyword.get(opts, :format, "text")
    fail_above = Keyword.get(opts, :fail_above)

    analysis_opts =
      if concurrency = opts[:concurrency] do
        [concurrency: concurrency]
      else
        []
      end

    case Analysis.extract_facts(modules, [analysis], analysis_opts) do
      {:ok, facts_dir} ->
        try do
          report(facts_dir, analysis, analysis_opts, format, fail_above)
        after
          File.rm_rf(Path.dirname(facts_dir))
        end

      {:error, reason} ->
        Mix.raise("Analysis failed: #{inspect(reason)}")
    end
  end

  defp report(facts_dir, analysis, analysis_opts, format, fail_above) do
    case Analysis.run_rules(facts_dir, analysis, analysis_opts) do
      {:ok, results} ->
        filtered = Analysis.filter_to_outputs(results, analysis)
        lines = Argus.Lines.from_facts_dir(facts_dir)
        Mix.shell().info(format_results(filtered, format, lines))

        if fail_above do
          total = count_results(filtered)

          if total > fail_above do
            Mix.raise("Analysis found #{total} results (threshold: #{fail_above})")
          end
        end

      {:error, reason} ->
        Mix.raise("Analysis failed: #{inspect(reason)}")
    end
  end

  defp resolve_modules(opts) do
    case Keyword.get(opts, :modules) do
      nil ->
        discover_project_modules(opts)

      modules_str ->
        modules_str
        |> String.split(",", trim: true)
        |> Enum.map(&parse_module/1)
    end
  end

  defp parse_module(":" <> erlang_mod) do
    String.to_existing_atom(erlang_mod)
  rescue
    ArgumentError ->
      Mix.raise("Unknown Erlang module: :#{erlang_mod}")
  end

  defp parse_module(elixir_mod) do
    Module.concat([elixir_mod])
  end

  defp discover_project_modules(opts) do
    modules = beams_in(Mix.Project.compile_path())

    if Keyword.get(opts, :include_deps, false) do
      modules ++ discover_dep_modules()
    else
      modules
    end
  end

  defp discover_dep_modules do
    build_lib = Path.join(Mix.Project.build_path(), "lib")

    Mix.Project.deps_apps()
    |> Enum.flat_map(fn app ->
      ebin = Path.join([build_lib, to_string(app), "ebin"])
      if File.dir?(ebin), do: beams_in(ebin), else: []
    end)
  end

  defp beams_in(ebin_dir) do
    ebin_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&beam_path_to_module/1)
  end

  defp beam_path_to_module(path) do
    name = Path.basename(path, ".beam")

    try do
      [String.to_existing_atom(name)]
    rescue
      ArgumentError ->
        # Stale .beam for a module that's no longer loaded — silently skip.
        []
    end
  end

  defp format_results(results, "json", _lines) do
    data =
      Map.new(results, fn {relation, rows} ->
        {relation, Enum.map(rows, &List.to_tuple/1)}
      end)

    inspect(data, pretty: true, limit: :infinity)
  end

  defp format_results(results, _text, lines) do
    results
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n\n", fn {relation, rows} ->
      header = "=== #{relation} (#{length(rows)} rows) ==="

      body =
        rows
        |> Enum.take(100)
        |> Enum.map_join("\n", fn row ->
          "  " <> Enum.map_join(row, "\t", &annotate_cell(&1, lines))
        end)

      truncated =
        if length(rows) > 100, do: "\n  ... (#{length(rows) - 100} more rows)", else: ""

      header <> "\n" <> body <> truncated
    end)
  end

  # Cells holding instruction or function IDs resolve to a source line
  # (schema v3 stamps every instruction); anything else — module names,
  # counts, placeholders — misses the tables and passes through as-is.
  defp annotate_cell(cell, lines) do
    case Argus.Lines.resolve(lines, cell) do
      nil -> cell
      line -> "#{cell} (line #{line})"
    end
  end

  defp count_results(results) do
    Enum.reduce(results, 0, fn {_, rows}, acc -> acc + length(rows) end)
  end
end
