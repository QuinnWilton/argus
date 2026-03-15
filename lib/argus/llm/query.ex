defmodule Argus.LLM.Query do
  @moduledoc """
  Natural language → Souffle Datalog query synthesis and execution.

  Takes a natural language question, asks the LLM to generate a Datalog
  query, validates it, extracts facts from the target modules, and runs
  the query through Souffle. On Souffle errors, feeds the error back to
  the LLM for correction (up to `:max_retries` times).
  """

  alias Argus.Analysis
  alias Argus.Extract
  alias Argus.Schema
  alias Argus.Souffle.CLI

  @max_retries 2

  @doc """
  Synthesizes and executes a Datalog query from a natural language question.

  Extracts facts from the given modules using all known extractors, generates
  a Datalog query via the LLM, validates it, and runs it through Souffle.

  Returns `{:ok, results}` or `{:error, reason}`.

  ## Options

  - `:max_retries` — max LLM retry attempts on Souffle error (default: 2)
  - `:extractors` — additional extractors (all analysis extractors are auto-included)
  - All `Argus.LLM.prompt/2` options
  - All `Argus.Souffle.CLI.run/3` options
  """
  @spec run(String.t(), [atom()], keyword()) :: {:ok, Analysis.result()} | {:error, term()}
  def run(question, modules, opts \\ []) do
    extractors = all_extractors(opts)
    opts = Keyword.put(opts, :extractors, extractors)

    with {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Extract.run(modules, facts_dir, opts),
         {:ok, dl_content} <- synthesize(question, opts),
         {:ok, results} <- execute_with_retries(dl_content, question, facts_dir, work_dir, opts) do
      {:ok, results}
    end
  end

  @doc """
  Synthesizes a Datalog query from a natural language question without executing it.

  Returns `{:ok, dl_content}` or `{:error, reason}`.
  """
  @spec synthesize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def synthesize(question, opts \\ []) do
    prompt_text = build_synthesis_prompt(question)
    Argus.LLM.prompt(prompt_text, opts)
  end

  @doc """
  Builds the synthesis prompt without sending it to the LLM.

  Useful for testing prompt construction.
  """
  @spec build_synthesis_prompt(String.t()) :: String.t()
  def build_synthesis_prompt(question) do
    [
      "You are a Souffle Datalog expert writing queries for Argus, a BEAM bytecode analysis tool.\n",
      "## Available input relations\n#{format_schema()}\n",
      "## Standard includes\n",
      "Include \"../clientlib/imports.dl\" for base facts + cfg_edge, call_edge, call_reachable, cfg_reachable.\n",
      "Declare layer 2 facts you need with .decl and .input.\n",
      "## Example query: find sync-call deadlock cycles\n#{example_query()}\n",
      "## Important\n",
      "- Generate ONLY the .dl file content, no markdown fences or explanation\n",
      "- Mark output relations with .output\n",
      "- Filter `!= \"dynamic\"` for symbolic fields that may be unresolved\n",
      "- Use descriptive relation names\n",
      "## Question\n#{question}"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Validates generated Datalog content.

  Checks that the content has at least one `.output` declaration and that
  all `.input` relation names exist in the schema.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(dl_content) do
    with :ok <- check_output_declarations(dl_content),
         :ok <- check_input_relations(dl_content) do
      :ok
    end
  end

  # Build schema context from Schema.all().
  defp format_schema do
    known_names = MapSet.new(Schema.names())

    Schema.all()
    |> Enum.map_join("\n", fn rel ->
      fields_str =
        Enum.map_join(rel.fields, ", ", fn {fname, ftype, fdoc} ->
          "#{fname}: #{ftype} /* #{fdoc} */"
        end)

      decl = ".decl #{rel.name}(#{fields_str})"
      input = if rel.name in known_names, do: "\n.input #{rel.name}", else: ""
      "#{decl}#{input}\n// #{rel.doc}"
    end)
  end

  # Embed a representative example analysis as a few-shot example.
  defp example_query do
    case File.read(Path.join(:code.priv_dir(:argus), "dl/analyses/call_cycle.dl")) do
      {:ok, content} -> content
      {:error, _} -> "// (example not available)"
    end
  end

  defp check_output_declarations(dl_content) do
    if dl_content =~ ~r/\.output\s+\w+/ do
      :ok
    else
      {:error, :no_output_declaration}
    end
  end

  defp check_input_relations(dl_content) do
    known = MapSet.new(Schema.names(), &to_string/1)

    # Also allow clientlib-provided derived relations.
    derived = MapSet.new(["cfg_edge", "call_edge", "call_reachable", "cfg_reachable"])
    allowed = MapSet.union(known, derived)

    unknown =
      ~r/\.input\s+(\w+)/
      |> Regex.scan(dl_content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(allowed, &1))

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_relations, unknown}}
    end
  end

  defp execute_with_retries(dl_content, question, facts_dir, work_dir, opts) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    do_execute(dl_content, question, facts_dir, work_dir, opts, 0, max_retries)
  end

  defp do_execute(dl_content, question, facts_dir, work_dir, opts, attempt, max_retries) do
    case validate(dl_content) do
      :ok ->
        rules_path = Path.join(work_dir, "query_#{attempt}.dl")
        File.write!(rules_path, resolve_includes(dl_content))

        case CLI.run(facts_dir, rules_path, opts) do
          {:ok, _results} = ok ->
            ok

          {:error, {:souffle_error, _code, error_output}} when attempt < max_retries ->
            retry_with_error(
              dl_content,
              question,
              error_output,
              facts_dir,
              work_dir,
              opts,
              attempt,
              max_retries
            )

          {:error, _} = error ->
            error
        end

      {:error, _} = error when attempt < max_retries ->
        retry_with_error(
          dl_content,
          question,
          inspect(error),
          facts_dir,
          work_dir,
          opts,
          attempt,
          max_retries
        )

      {:error, _} = error ->
        error
    end
  end

  defp retry_with_error(
         prev_dl,
         question,
         error_msg,
         facts_dir,
         work_dir,
         opts,
         attempt,
         max_retries
       ) do
    retry_prompt =
      [
        build_synthesis_prompt(question),
        "\n## Previous attempt (failed)\n```\n#{prev_dl}\n```\n",
        "## Error\n#{error_msg}\n",
        "Fix the error and generate the corrected .dl file content."
      ]
      |> Enum.join("\n")

    case Argus.LLM.prompt(retry_prompt, opts) do
      {:ok, new_dl} ->
        do_execute(new_dl, question, facts_dir, work_dir, opts, attempt + 1, max_retries)

      {:error, _} = error ->
        error
    end
  end

  # Collect all unique extractors from all built-in analyses, plus any from opts.
  defp all_extractors(opts) do
    analysis_extractors =
      Analysis.builtin_analysis_modules()
      |> Enum.flat_map(& &1.extractors())
      |> Enum.uniq()

    extra = Keyword.get(opts, :extractors, [])
    Enum.uniq(analysis_extractors ++ extra)
  end

  # Rewrite relative .include paths to absolute paths so Souffle can
  # find clientlib files when the .dl is in a temp directory.
  defp resolve_includes(dl_content) do
    clientlib_dir = Path.join(:code.priv_dir(:argus), "dl/clientlib")
    base_dir = Path.join(:code.priv_dir(:argus), "dl")

    dl_content
    |> then(fn content ->
      Regex.replace(~r/\.include\s+"\.\.\/clientlib\/([^"]+)"/, content, fn _match, file ->
        ~s(.include "#{Path.join(clientlib_dir, file)}")
      end)
    end)
    |> then(fn content ->
      Regex.replace(~r/\.include\s+"\.\.\/base\.dl"/, content, fn _match ->
        ~s(.include "#{Path.join(base_dir, "base.dl")}")
      end)
    end)
  end

  defp create_work_dir do
    case System.tmp_dir() do
      nil ->
        {:error, :no_tmp_dir}

      tmp ->
        dir = Path.join(tmp, "argus_query_#{System.unique_integer([:positive])}")
        File.rm_rf(dir)

        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end
end
