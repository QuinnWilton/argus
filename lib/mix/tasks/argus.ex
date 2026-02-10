defmodule Mix.Tasks.Argus do
  @shortdoc "Run BEAM program analysis via Souffle Datalog"

  @moduledoc """
  Runs Argus analysis against project modules.

  ## Usage

      mix argus ANALYSIS [options]

  ## Built-in analyses

  - `cfg` — control flow graph edges
  - `callgraph` — call graph edges
  - `reachability` — transitive CFG and call reachability
  - `reaching_def` — reaching definitions and def-use chains
  - `liveness` — live variable analysis and dead definition detection
  - `tail_call` — tail call identification and recursion detection
  - `message_flow` — message send/receive pairing across functions
  - `supervision` — supervision tree structure and anti-patterns
  - `ets` — ETS table ownership, concurrency, and lifecycle analysis
  - `coupled_siblings` — siblings under one_for_one with transitive coupling

  ## Custom analysis

      mix argus custom path/to/rules.dl

  ## Options

  - `--modules` — comma-separated list of modules to analyze (default: all project modules)
  - `--include-deps` — include dependency modules in analysis
  - `--format` — output format: text (default), json, dot
  - `--fail-above N` — exit with non-zero status if more than N results
  - `--concurrency N` — number of parallel workers (default: number of schedulers)

  ## Examples

      mix argus cfg
      mix argus callgraph --modules Enum,:lists
      mix argus callgraph --format dot | dot -Tsvg -o graph.svg
      mix argus supervision --fail-above 0
      mix argus custom my_rules.dl
  """

  use Mix.Task

  alias Argus.Analysis
  alias Argus.Souffle.CLI

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    unless CLI.available?() do
      Mix.raise("souffle binary not found on PATH. Install Souffle to use Argus.")
    end

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          modules: :string,
          include_deps: :boolean,
          format: :string,
          fail_above: :integer,
          concurrency: :integer
        ]
      )

    case positional do
      [] ->
        Mix.raise("Usage: mix argus ANALYSIS [options]\nRun `mix help argus` for details.")

      ["custom", rules_path | _] ->
        run_analysis({:custom, rules_path}, opts)

      [analysis_name | _] ->
        case parse_analysis(analysis_name) do
          {:ok, analysis} -> run_analysis(analysis, opts)
          {:error, msg} -> Mix.raise(msg)
        end
    end
  end

  defp parse_analysis(name) do
    case Enum.find(Analysis.builtin_analyses(), &(to_string(&1) == name)) do
      nil ->
        {:error,
         "Unknown analysis: #{name}\nAvailable: #{Enum.join(Analysis.builtin_analyses(), ", ")}"}

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

    case Analysis.run(modules, analysis, analysis_opts) do
      {:ok, results} ->
        output = format_results(results, format)
        Mix.shell().info(output)

        if fail_above do
          total = count_results(results)

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
    try do
      String.to_existing_atom(erlang_mod)
    rescue
      ArgumentError ->
        Mix.raise("Unknown Erlang module: :#{erlang_mod}")
    end
  end

  defp parse_module(elixir_mod) do
    Module.concat([elixir_mod])
  end

  defp discover_project_modules(opts) do
    compile_path = Mix.Project.compile_path()

    beam_files =
      compile_path
      |> Path.join("*.beam")
      |> Path.wildcard()

    modules =
      Enum.map(beam_files, fn path ->
        path
        |> Path.basename(".beam")
        |> String.to_existing_atom()
      end)

    if Keyword.get(opts, :include_deps, false) do
      dep_modules = discover_dep_modules()
      modules ++ dep_modules
    else
      modules
    end
  end

  defp discover_dep_modules do
    Mix.Project.deps_paths()
    |> Enum.flat_map(fn {_dep, path} ->
      ebin = Path.join([path, "_build", to_string(Mix.env()), "lib", "*", "ebin"])

      ebin
      |> Path.wildcard()
      |> Enum.flat_map(fn dir ->
        dir
        |> Path.join("*.beam")
        |> Path.wildcard()
        |> Enum.map(fn p ->
          p |> Path.basename(".beam") |> String.to_existing_atom()
        end)
      end)
    end)
  end

  defp format_results(results, "json") do
    data =
      Map.new(results, fn {relation, rows} ->
        {relation, Enum.map(rows, &List.to_tuple/1)}
      end)

    inspect(data, pretty: true, limit: :infinity)
  end

  defp format_results(results, "dot") do
    # Generate DOT format for graph relations (cfg_edge, call_edge).
    edges =
      results
      |> Enum.flat_map(fn
        {name, rows} when name in ["cfg_edge", "call_edge", "cfg_reachable", "call_reachable"] ->
          Enum.map(rows, fn [from, to] -> {from, to} end)

        _ ->
          []
      end)

    edge_lines =
      Enum.map_join(edges, "\n", fn {from, to} ->
        ~s(  "#{escape_dot(from)}" -> "#{escape_dot(to)}";)
      end)

    """
    digraph argus {
      rankdir=LR;
      node [shape=box, fontname="monospace"];

    #{edge_lines}
    }
    """
  end

  defp format_results(results, _text) do
    results
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n\n", fn {relation, rows} ->
      header = "=== #{relation} (#{length(rows)} rows) ==="

      body =
        rows
        |> Enum.take(100)
        |> Enum.map_join("\n", fn row -> "  " <> Enum.join(row, "\t") end)

      truncated =
        if length(rows) > 100, do: "\n  ... (#{length(rows) - 100} more rows)", else: ""

      header <> "\n" <> body <> truncated
    end)
  end

  defp escape_dot(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp count_results(results) do
    Enum.reduce(results, 0, fn {_, rows}, acc -> acc + length(rows) end)
  end
end
