defmodule Mix.Tasks.Argus.Query do
  @shortdoc "Run natural language queries against BEAM bytecode via LLM + Datalog"

  @moduledoc """
  Synthesizes and executes a Datalog query from a natural language question.

  The LLM generates a Souffle Datalog program from the question, Argus
  extracts facts from the target modules, and Souffle evaluates the query.

  ## Usage

      mix argus.query "which modules call GenServer.call with infinity timeout?"
      mix argus.query --show-dl "find ETS tables created without :named_table"
      mix argus.query --modules MyApp.Server "what sync calls does this make?"

  ## Options

  - `--modules` — comma-separated list of modules to analyze (default: all project modules)
  - `--show-dl` — print the generated Datalog without executing it
  - `--format` — output format: text (default), json
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          modules: :string,
          show_dl: :boolean,
          format: :string
        ]
      )

    question = Enum.join(positional, " ")

    if question == "" do
      Mix.raise("Usage: mix argus.query \"your question here\" [options]")
    end

    unless Argus.LLM.available?() do
      Mix.raise("LLM binary not found. Install claude CLI or set ARGUS_LLM_BIN.")
    end

    unless Argus.Souffle.CLI.available?() do
      Mix.raise("souffle binary not found on PATH. Install Souffle to use Argus.")
    end

    if opts[:show_dl] do
      show_datalog(question, opts)
    else
      run_query(question, opts)
    end
  end

  defp show_datalog(question, _opts) do
    case Argus.LLM.Query.synthesize(question) do
      {:ok, dl_content} ->
        Mix.shell().info(dl_content)

      {:error, reason} ->
        Mix.raise("Query synthesis failed: #{inspect(reason)}")
    end
  end

  defp run_query(question, opts) do
    modules = resolve_modules(opts)
    format = Keyword.get(opts, :format, "text")

    case Argus.LLM.Query.run(question, modules) do
      {:ok, results} ->
        Mix.shell().info(format_results(results, format))

      {:error, reason} ->
        Mix.raise("Query failed: #{inspect(reason)}")
    end
  end

  defp resolve_modules(opts) do
    case Keyword.get(opts, :modules) do
      nil ->
        discover_project_modules()

      modules_str ->
        modules_str
        |> String.split(",", trim: true)
        |> Enum.map(&Module.concat([&1]))
    end
  end

  defp discover_project_modules do
    compile_path = Mix.Project.compile_path()

    compile_path
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.basename(".beam")
      |> String.to_existing_atom()
    end)
  end

  defp format_results(results, "json") do
    data =
      Map.new(results, fn {relation, rows} ->
        {relation, Enum.map(rows, &List.to_tuple/1)}
      end)

    inspect(data, pretty: true, limit: :infinity)
  end

  defp format_results(results, _text) do
    results
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "_") end)
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
end
