# Analyzes an external Elixir/Erlang project with Argus.
#
# Usage:
#   mix run scripts/analyze_project.exs /path/to/project [analysis]
#
# The project must already be compiled. This script:
# 1. Adds the project's ebin directories to the code path
# 2. Discovers project modules (skipping deps)
# 3. Runs the specified analysis (default: coupled_siblings)
# 4. Pretty-prints supervision structure and findings

defmodule Argus.Scripts.AnalyzeProject do
  @doc false
  def run(args) do
    {project_path, analysis} = parse_args(args)
    project_path = Path.expand(project_path)

    unless File.dir?(project_path) do
      abort("Project path does not exist: #{project_path}")
    end

    IO.puts("Analyzing: #{project_path}")
    IO.puts("Analysis: #{analysis}")
    IO.puts("")

    # Add project ebin dirs to code path.
    ebin_dirs = discover_ebin_dirs(project_path)

    if ebin_dirs == [] do
      abort("No ebin directories found. Is the project compiled?")
    end

    Enum.each(ebin_dirs, fn dir ->
      Code.prepend_path(dir)
    end)

    IO.puts("Added #{length(ebin_dirs)} ebin directories to code path")

    # Discover project modules (from the project's own ebin, not deps).
    project_ebin = find_project_ebin(project_path)
    modules = discover_modules(project_ebin)

    if modules == [] do
      abort("No modules found in project ebin")
    end

    IO.puts("Found #{length(modules)} project modules")
    IO.puts("")

    # Print supervision structure first.
    print_supervision_structure(modules)

    # Run the analysis.
    IO.puts("--- Running #{analysis} analysis ---")
    IO.puts("")

    extractors = [Argus.Extractors.Supervision, Argus.Extractors.OTP]

    case Argus.analyze(modules, analysis, extractors: extractors) do
      {:ok, results} ->
        print_results(results)

      {:error, reason} ->
        abort("Analysis failed: #{inspect(reason)}")
    end
  end

  defp parse_args([project_path]) do
    {project_path, :coupled_siblings}
  end

  defp parse_args([project_path, analysis_str]) do
    analysis =
      try do
        String.to_existing_atom(analysis_str)
      rescue
        ArgumentError -> abort("Unknown analysis: #{analysis_str}")
      end

    {project_path, analysis}
  end

  defp parse_args(_) do
    abort("Usage: mix run scripts/analyze_project.exs /path/to/project [analysis]")
  end

  defp discover_ebin_dirs(project_path) do
    # Find all ebin dirs under _build.
    Path.join([project_path, "_build", "**", "ebin"])
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp find_project_ebin(project_path) do
    # The project's own compiled beam files live under
    # _build/dev/lib/<app_name>/ebin. Detect app name from mix.exs.
    app_name = detect_app_name(project_path)

    candidates = [
      Path.join([project_path, "_build", "dev", "lib", app_name, "ebin"]),
      Path.join([project_path, "_build", "prod", "lib", app_name, "ebin"])
    ]

    Enum.find(candidates, &File.dir?/1) ||
      abort("Could not find project ebin directory for app '#{app_name}'")
  end

  defp detect_app_name(project_path) do
    mix_exs = Path.join(project_path, "mix.exs")

    unless File.exists?(mix_exs) do
      abort("No mix.exs found at #{project_path}")
    end

    content = File.read!(mix_exs)

    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> Path.basename(project_path)
    end
  end

  defp discover_modules(ebin_dir) do
    ebin_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.basename(".beam")
      |> String.to_atom()
    end)
    |> Enum.sort()
  end

  defp print_supervision_structure(modules) do
    IO.puts("--- Supervision structure ---")
    IO.puts("")

    Enum.each(modules, fn mod ->
      path = to_string(:code.which(mod))

      case BeamSpy.BeamFile.disassemble(path) do
        {:ok, data} ->
          facts = Argus.Extractors.Supervision.extract(data)

          if Map.has_key?(facts, :supervisor) do
            [mod_str, strategy] = hd(facts[:supervisor])
            IO.puts("  #{mod_str} (#{strategy})")

            children = Map.get(facts, :supervisor_child, [])

            children
            |> Enum.sort_by(fn [_, pos | _] -> String.to_integer(pos) end)
            |> Enum.each(fn [_, pos, child, restart, type] ->
              IO.puts("    #{pos}. #{child} (#{restart}, #{type})")
            end)

            IO.puts("")
          end

        {:error, _} ->
          :skip
      end
    end)
  end

  # Intermediate relations produced by Souffle that aren't findings.
  @noise_relations ~w(call_edge call_reachable module_reaches)

  defp print_results(results) do
    findings =
      results
      |> Enum.reject(fn {name, _} -> name in @noise_relations end)
      |> Enum.reject(fn {_, rows} -> rows == [] end)

    if findings == [] do
      IO.puts("No findings.")
      return()
    end

    findings
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {relation, rows} ->
      IO.puts("=== #{relation} (#{length(rows)} findings) ===")
      IO.puts("")

      Enum.each(rows, fn row ->
        IO.puts("  #{Enum.join(row, "  |  ")}")
      end)

      IO.puts("")
    end)
  end

  defp return, do: :ok

  defp abort(msg) do
    IO.puts(:stderr, "Error: #{msg}")
    System.halt(1)
  end
end

Argus.Scripts.AnalyzeProject.run(System.argv())
